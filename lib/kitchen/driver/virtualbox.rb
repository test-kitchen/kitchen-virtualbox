# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "fileutils" unless defined?(FileUtils)
require "kitchen"
require "kitchen/box/local_archive"
require "kitchen/box/source"
require "kitchen/box/ssh_bootstrap"
require "kitchen/state_file"
require "mixlib/shellout" unless defined?(Mixlib::ShellOut)
require "securerandom" unless defined?(SecureRandom)
require "socket" unless defined?(Socket)
require "tempfile" unless defined?(Tempfile)
require "tmpdir" unless defined?(Dir.mktmpdir)

module Kitchen
  module Driver
    class Virtualbox < Base
      kitchen_driver_api_version 2
      plugin_version "0.1.0"

      default_config :box
      default_config :box_manifest
      default_config :box_cache
      default_config :source_vm
      default_config :source_snapshot
      default_config :vboxmanage, "VBoxManage"
      default_config :insert_key, true

      include Box::Source

      def create(state)
        source = config[:source_vm]
        snapshot = config[:source_snapshot]
        unless snapshot.nil? || (snapshot.is_a?(String) && !snapshot.strip.empty? && source && config[:box].nil?)
          raise ActionFailed, "Set driver.source_snapshot to an existing snapshot name or UUID with driver.source_vm and without driver.box"
        end
        unless source.nil? || (source.is_a?(String) && !source.strip.empty? && config[:box].nil?)
          raise ActionFailed, "Set driver.source_vm to a registered VirtualBox VM name or UUID without driver.box"
        end

        prepare_state(state)
        verify_clone_request(source, snapshot, state)
        uuid = registered_uuid(state) || (source ? clone_vm(source, snapshot, state) : import_vm(state))
        record_linked_clone_media(uuid, state) if state[:virtualbox_linked_clone]
        state[:virtualbox_uuid] = uuid
        checkpoint(state)
        ensure_running(uuid, state)
        configure_ssh(uuid, state)
        instance.transport.connection(state).wait_until_ready
      end

      def destroy(state)
        return unless state[:virtualbox_token]

        directory = vm_directory(state)
        if (uuid = registered_uuid(state))
          if state[:virtualbox_linked_clone]
            record_linked_clone_media(uuid, state)
            disks = hard_disks
            state.fetch(:virtualbox_linked_media).each do |chain, identity|
              verify_linked_disk(chain, identity, directory, disks)
            end
            state[:virtualbox_destroying] = true
            checkpoint(state)
          end
          status = vm_info(uuid).fetch("VMState")
          case status
          when "running", "paused", "stuck"
            vbox("controlvm", uuid, "poweroff")
          when "saved"
            vbox("discardstate", uuid)
          end
          # Linked clones share a disk chain with their source. Delete only files we own.
          options = state[:virtualbox_linked_clone] ? [] : ["--delete"]
          vbox("unregistervm", uuid, *options)
        end
        if state[:virtualbox_linked_clone]
          close_linked_clone_media(directory, state)
        elsif File.directory?(directory)
          FileUtils.remove_entry_secure(directory)
        end
        release_box_source(state)
      end

      private

      def hard_disks
        vbox("list", "hdds").split(/\n\s*\n/).to_h do |entry|
          uuid = entry[/^UUID:[ \t]+([0-9a-f-]+)$/i, 1]
          parent = entry[/^Parent UUID:[ \t]+(\S+)$/, 1]
          location = entry[/^Location:[ \t]+(.+)$/, 1]
          raise ActionFailed, "VirtualBox returned an incomplete hard disk record" unless uuid && parent && location

          [uuid.downcase, [canonical_disk_path(location), parent.downcase, location]]
        end
      end

      def canonical_disk_path(path)
        File.realpath(path)
      rescue SystemCallError
        nil
      end

      def record_linked_clone_media(uuid, state)
        return if state[:virtualbox_linked_media]

        existing = state[:virtualbox_existing_disks]
        raise ActionFailed, "VirtualBox linked clone state is missing its original disk inventory" unless existing

        directory = vm_directory(state)
        disks = hard_disks
        info = vm_info(uuid)
        image_ids = info.filter_map { |key, id| id.downcase if /-ImageUUID-\d+-\d+"?\z/.match?(key) && id }
        owned = (image_ids.uniq & disks.keys) - existing
        raise ActionFailed, "VirtualBox did not report a linked clone disk" if owned.empty?

        state[:virtualbox_linked_media] = owned.map do |id|
          path, parent = disks.fetch(id)
          unless inside_directory?(path, directory) && parent != "base"
            raise ActionFailed, "VirtualBox disk #{id} is outside the linked clone directory or has no parent"
          end

          chain = linked_parent_chain(id, disks)
          unless chain.drop(1).all? { |ancestor, _, _| existing.include?(ancestor) }
            raise ActionFailed, "VirtualBox disk #{id} has an unexpected parent chain"
          end

          [chain, disk_file_identity(path)]
        end
        state[:virtualbox_linked_config] = info["CfgFile"]
        state[:virtualbox_linked_logs] = info["LogFldr"]
        checkpoint(state)
      end

      def linked_parent_chain(id, disks)
        chain = []
        until id == "base"
          path, parent = disks[id]
          if !path || chain.any? { |ancestor, _, _| ancestor == id }
            raise ActionFailed, "VirtualBox could not verify linked disk #{id} and its parent chain"
          end

          chain << [id, path, parent]
          id = parent
        end
        chain
      end

      def close_linked_clone_media(directory, state)
        owned = state[:virtualbox_linked_media]
        return unless owned

        owned.each do |chain, identity|
          id, path, = chain.first
          disks = hard_disks
          next if !disks.key?(id) && !File.exist?(path) && !File.symlink?(path)

          verify_linked_disk(chain, identity, directory, disks)
          if disks.key?(id)
            vbox("closemedium", "disk", id, "--delete")
          else
            # Unregistering can also close a medium. Only unlink the same file we recorded.
            File.unlink(path)
          end
        end
        remove_linked_clone_artifacts(directory, state) if File.directory?(directory)
      end

      def verify_linked_disk(chain, identity, directory, disks)
        id, path, parent = chain.first
        other_disk_at_path = disks.any? { |other, (location, _)| other != id && location == path }
        current_chain = disks.key?(id) ? linked_parent_chain(id, disks) : [chain.first, *linked_parent_chain(parent, disks)]
        unless inside_directory?(path, directory) && !other_disk_at_path && current_chain == chain &&
            canonical_disk_path(path) == path && disk_file_identity(path) == identity
          raise ActionFailed, "VirtualBox linked disk #{id} or its parent chain changed"
        end
      end

      def disk_file_identity(path)
        stat = File.stat(path)
        [stat.dev, stat.ino]
      end

      def remove_linked_clone_artifacts(directory, state)
        files = [File.join(directory, "ssh_key")]
        if (config_file = state[:virtualbox_linked_config])
          files.concat([config_file, "#{config_file}-prev", "#{config_file}-tmp", config_file.sub(/\.vbox\z/, ".nvram")])
        end
        if (logs = state[:virtualbox_linked_logs]) && inside_directory?(canonical_disk_path(logs), directory)
          files.concat(Dir.glob("VBox.log{,.[0-9]*}", base: logs).map { |name| File.join(logs, name) })
        end

        registered = hard_disks.values.flat_map { |path, _, location| [path, location] }
        files.uniq.each do |file|
          path = canonical_disk_path(file)
          next unless inside_directory?(path, directory) && File.file?(file)
          next if File.symlink?(file) || registered.include?(path) || registered.include?(file)

          File.unlink(file)
        end
        Dir.glob("**/*/", base: directory).reverse_each do |relative|
          path = File.join(directory, relative.delete_suffix("/"))
          Dir.rmdir(path) if !File.symlink?(path) && Dir.empty?(path)
        end
        Dir.rmdir(directory) if Dir.empty?(directory)
      end

      def inside_directory?(path, directory)
        path&.start_with?("#{directory}/")
      end

      def verify_clone_request(source, snapshot, state)
        previous = state[:virtualbox_clone_request]
        if state[:virtualbox_destroying] || (previous && previous != [source, snapshot])
          raise ActionFailed, "Run kitchen destroy before recreating the VirtualBox instance with this configuration"
        end
      end

      def prepare_state(state)
        return if state[:virtualbox_token]

        state[:virtualbox_token] = SecureRandom.uuid
        state[:virtualbox_name] = "kitchen-#{instance.name}-#{state[:virtualbox_token]}"
        state[:virtualbox_uuid] = state[:virtualbox_token] if config[:source_vm]
        checkpoint(state)
      end

      def checkpoint(state)
        StateFile.new(config[:kitchen_root], instance.name).write(state)
      end

      def vm_directory(state)
        token = state.fetch(:virtualbox_token)
        unless /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/.match?(token)
          raise ActionFailed, "Invalid VirtualBox instance ID in Kitchen state"
        end

        parent = File.join(File.realpath(config[:kitchen_root]), ".kitchen")
        parent = File.realpath(parent) if File.directory?(parent)
        directory = File.join(parent, "virtualbox-#{token}")
        if File.symlink?(directory)
          raise ActionFailed, "VirtualBox instance directory is a symlink: #{directory}"
        end

        directory
      end

      def registered_uuid(state)
        registered_vms.find do |name, uuid|
          state[:virtualbox_uuid] ? uuid == state[:virtualbox_uuid] : name == state[:virtualbox_name]
        end&.last
      end

      def registered_vms
        vbox("list", "vms").each_line.filter_map do |line|
          entry = /\A"(.*)" \{([0-9a-f-]+)\}\s*\z/i.match(line)
          entry&.captures
        end
      end

      def clone_vm(source, snapshot, state)
        vms = registered_vms
        source_vm = vms.find { |_, uuid| uuid.casecmp?(source) } || vms.find { |name, _| name == source }
        raise ActionFailed, "VirtualBox source VM is not registered: #{source}" unless source_vm

        source_uuid = source_vm.last
        status = vm_info(source_uuid).fetch("VMState")
        unless status == "poweroff"
          raise ActionFailed, "VirtualBox source VM #{source.inspect} must be powered off (current state: #{status})"
        end

        clone_uuid = state.fetch(:virtualbox_token)
        state[:virtualbox_uuid] = clone_uuid
        state[:virtualbox_clone_request] ||= [source, snapshot]
        state[:virtualbox_linked_clone] = !snapshot.nil?
        state[:virtualbox_existing_disks] ||= hard_disks.keys if snapshot
        checkpoint(state)
        directory = vm_directory(state)
        FileUtils.mkdir_p(directory, mode: 0o700)
        clone_options = snapshot ? ["--options=Link", "--snapshot=#{snapshot}"] : []
        begin
          vbox("clonevm", source_uuid, "--mode", "machine", "--name", state.fetch(:virtualbox_name),
            "--uuid", clone_uuid, "--basefolder", directory, "--register", *clone_options)
        rescue ActionFailed => e
          raise unless snapshot

          raise ActionFailed, "Could not link VirtualBox snapshot #{snapshot.inspect} on #{source.inspect}. " \
            "Choose an existing snapshot taken while the source was powered off. #{e.message}"
        end
        registered_uuid(state) || raise(ActionFailed, "VirtualBox did not register #{state[:virtualbox_name]}")
      end

      def import_vm(state)
        source = box_source("virtualbox", state) { checkpoint(state) }
        unless File.file?(source) && File.extname(source) == ".box"
          raise ActionFailed, "VirtualBox driver.box must point to a local VirtualBox .box archive: #{source}"
        end

        checkpoint(state) if state.delete(:virtualbox_uuid)
        directory = vm_directory(state)
        FileUtils.mkdir_p(directory, mode: 0o700)
        Dir.mktmpdir("box-", directory) do |staging|
          Box::LocalArchive.new(source, provider: "virtualbox").extract(staging) { |*args| command(*args) }
          appliance = File.join(staging, "box.ovf")
          unless File.file?(appliance) && !File.symlink?(appliance)
            raise ActionFailed, "VirtualBox box is missing a regular box.ovf: #{source}"
          end

          vbox("import", appliance, "--vsys", "0", "--vmname", state.fetch(:virtualbox_name), "--basefolder", directory)
        end
        registered_uuid(state) || raise(ActionFailed, "VirtualBox did not register #{state[:virtualbox_name]}")
      rescue Box::LocalArchive::InvalidBox => e
        raise ActionFailed, e.message
      end

      def ensure_running(uuid, state)
        info = vm_info(uuid)
        if state[:virtualbox_linked_clone] && info.fetch("VMState") == "saved"
          raise ActionFailed, "Linked clone has a saved runtime state. Run kitchen destroy and choose a snapshot taken while the source was powered off."
        end

        if info.fetch("VMState") == "running"
          rule = forwarding_rules(info).find { |value| value.start_with?("kitchen-ssh,tcp,127.0.0.1,") }
          raise ActionFailed, "Running VirtualBox VM is missing its Kitchen SSH forwarding rule" unless rule

          state[:port] = Integer(rule.split(",").fetch(3))
        else
          # Registered-source clones use the Kitchen token as their VM UUID.
          if uuid == state[:virtualbox_token]
            isolate_clone(uuid, info)
            info = vm_info(uuid)
          end
          forwarding_rules(info).each do |forwarding_rule|
            vbox("modifyvm", uuid, "--nat-pf1", "delete", forwarding_rule.split(",").first)
          end
          TCPServer.open("127.0.0.1", 0) { |socket| state[:port] = socket.addr[1] }
          vbox("modifyvm", uuid, "--nic1", "nat", "--nat-pf1", "kitchen-ssh,tcp,127.0.0.1,#{state[:port]},,#{instance.transport[:port] || 22}")
          vbox("startvm", uuid, "--type", "headless")
        end
        state[:hostname] = "127.0.0.1"
      end

      def forwarding_rules(info)
        info.select { |key, _| key.start_with?("Forwarding(") }.values
      end

      def isolate_clone(uuid, info)
        options = %w{--vrde off --clipboard-mode disabled --drag-and-drop disabled
          --usb-ohci off --usb-ehci off --usb-xhci off --nic-trace1 off --nic1 nat --cable-connected1 on}
        info.each do |key, value|
          if (adapter = /\Anic([0-9]+)\z/.match(key))
            options.push("--#{key}", "none") if adapter[1].to_i > 1 && value != "none"
          elsif key.start_with?("SharedFolderNameMachineMapping")
            vbox("sharedfolder", "remove", uuid, "--name", value)
          end
        end
        vbox("modifyvm", uuid, *options)
      end

      def configure_ssh(uuid, state)
        transport = instance.transport
        if !config[:insert_key] || transport[:ssh_key] || transport[:password]
          state.delete(:ssh_key) if state.delete(:virtualbox_generated_key)
          state.delete(:username) if state.delete(:virtualbox_generated_key_user)
          return
        end

        user = transport[:username]
        user = "vagrant" if user.nil? || user == "root"
        state[:ssh_key] = Box::SshBootstrap.install(vm_directory(state), runner: method(:command)) do |arguments|
          install_guest_key(uuid, user, arguments)
        end
        state[:username] = user
        state[:virtualbox_generated_key] = true
        state[:virtualbox_generated_key_user] = true
      end

      def install_guest_key(uuid, user, arguments)
        Tempfile.create("kitchen-vbox-password") do |password|
          password.write("vagrant\n")
          password.flush
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 90
          begin
            vbox("guestcontrol", uuid, "run", "--username", user, "--passwordfile", password.path, "--exe", "/bin/sh",
              "--timeout", "10000", "--", *arguments)
          rescue ActionFailed => e
            raise ActionFailed, "Could not bootstrap SSH through VirtualBox Guest Additions: #{e.message}" if
              Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep 2
            retry
          end
        end
      end

      def vm_info(uuid)
        vbox("showvminfo", uuid, "--machinereadable").each_line.to_h do |line|
          key, value = line.strip.split("=", 2)
          [key, value&.delete_prefix('"')&.delete_suffix('"')]
        end
      end

      def vbox(*arguments)
        command(config[:vboxmanage], *arguments)
      end

      def command(*arguments)
        debug("Running #{arguments.first(3).inspect}")
        process = Mixlib::ShellOut.new(*arguments, timeout: 600)
        process.run_command
        process.error!
        process.stdout
      rescue Mixlib::ShellOut::ShellCommandFailed, Mixlib::ShellOut::CommandTimeout, SystemCallError => e
        raise ActionFailed, e.message
      end
    end
  end
end
