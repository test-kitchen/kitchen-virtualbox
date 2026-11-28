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
        uuid = registered_uuid(state) || (source ? clone_vm(source, snapshot, state) : import_vm(state))
        state[:virtualbox_uuid] = uuid
        checkpoint(state)
        ensure_running(uuid, state)
        configure_ssh(uuid, state)
        instance.transport.connection(state).wait_until_ready
      end

      def destroy(state)
        return unless state[:virtualbox_token]

        if (uuid = registered_uuid(state))
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
        directory = vm_directory(state)
        close_linked_clone_media(directory) if state[:virtualbox_linked_clone] && File.directory?(directory) && !File.symlink?(directory)
        FileUtils.remove_entry_secure(directory) if File.exist?(directory)
        release_box_source(state)
      end

      private

      def close_linked_clone_media(directory)
        prefix = "#{File.realpath(directory)}/"
        vbox("list", "hdds").split(/\n\s*\n/).reverse_each do |entry|
          path = entry[/^Location:[ \t]+(.+)$/, 1]
          next unless path&.start_with?(prefix)
          next if File.exist?(path) && File.realpath(path) != path

          uuid = entry[/^UUID:[ \t]+([0-9a-f-]+)$/, 1]
          raise ActionFailed, "VirtualBox did not report a UUID for clone disk #{path}" unless uuid

          vbox("closemedium", "disk", uuid)
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

        File.join(config[:kitchen_root], ".kitchen", "virtualbox-#{token}")
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
        state[:virtualbox_linked_clone] = true if snapshot
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
          forwarding_rules(info).each do |rule|
            vbox("modifyvm", uuid, "--nat-pf1", "delete", rule.split(",").first)
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
