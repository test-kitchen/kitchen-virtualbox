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
      default_config :vboxmanage, "VBoxManage"
      default_config :insert_key, true
      default_config :disk_size_mib

      include Box::Source

      def create(state)
        size = config[:disk_size_mib]
        unless size.nil? || (size.is_a?(Integer) && size > 0)
          raise ActionFailed, "VirtualBox driver.disk_size_mib must be a positive integer"
        end

        prepare_state(state)
        uuid = registered_uuid(state)
        unless uuid
          reset_missing_vm(state) if state[:virtualbox_uuid]
          uuid = import_vm(state)
        end
        unless state[:virtualbox_uuid]
          directory = File.realpath(vm_directory(state))
          paths = storage_slots(vm_info(uuid)).values
          state[:virtualbox_media_identities] = registered_disks.filter_map do |id, path|
            next unless paths.include?(path) && path.start_with?("#{directory}/")

            identity = disk_identity(path)
            [id.to_sym, identity] if identity
          end.to_h
        end
        state[:virtualbox_uuid] = uuid
        checkpoint(state)
        attach_blank_disk(uuid, state, size) if size
        ensure_running(uuid, state)
        configure_ssh(uuid, state)
        instance.transport.connection(state).wait_until_ready
      end

      def destroy(state)
        return unless state[:virtualbox_token]

        directory = vm_directory(state)
        if (uuid = registered_uuid(state))
          snapshots = vbox("snapshot", uuid, "list", "--machinereadable", returns: [0, 1]).strip
          unless snapshots == "This machine does not have any snapshots"
            raise ActionFailed, "Cannot destroy the VirtualBox VM while snapshot media ownership is unverified"
          end

          info = vm_info(uuid)
          status = info.fetch("VMState")
          case status
          when "running", "paused", "stuck"
            vbox("controlvm", uuid, "poweroff")
          when "saved"
            vbox("discardstate", uuid)
          end
          detach_unowned_media(uuid, info, state)
          vbox("unregistervm", uuid, "--delete")
        end
        clean_owned_media(state)
        FileUtils.rm_f(File.join(directory, "ssh_key"))
        Dir.rmdir(directory) if File.directory?(directory) && Dir.empty?(directory)
        release_box_source(state)
      end

      private

      def attach_blank_disk(uuid, state, size)
        unless state[:virtualbox_media_identities]
          raise ActionFailed, "Recreate the VirtualBox instance before enabling driver.disk_size_mib"
        end

        info = vm_info(uuid)
        id = state[:virtualbox_blank_disk_uuid]
        if state[:virtualbox_disk_size_mib] && state[:virtualbox_disk_size_mib] != size
          raise ActionFailed, "Destroy the VirtualBox instance before changing driver.disk_size_mib"
        end

        if id
          path = verified_owned_disks(state)[id]
          raise ActionFailed, "Cannot verify the VirtualBox blank disk identity" unless path

          return if storage_slots(info).value?(path)
        end

        unless info.fetch("VMState") == "poweroff"
          raise ActionFailed, "Power off the VirtualBox instance before attaching a blank test disk"
        end

        controller, port, device = ensure_free_disk_slot(uuid, info)
        unless id
          path = File.join(File.realpath(vm_directory(state)), "test-disk-#{SecureRandom.uuid}.vdi")
          vbox("createmedium", "disk", "--filename", path, "--size", size.to_s, "--format", "VDI")
          id = registered_disks.key(path)
          identity = disk_identity(path)
          raise ActionFailed, "VirtualBox did not report the new blank disk identity" unless id && identity

          state[:virtualbox_media_identities][id.to_sym] = identity
          state[:virtualbox_blank_disk_uuid] = id
          state[:virtualbox_disk_size_mib] = size
          checkpoint(state)
        end
        vbox("storageattach", uuid, "--storagectl", controller, "--port", port, "--device", device,
          "--type", "hdd", "--medium", id)
      end

      def ensure_free_disk_slot(uuid, info)
        slots = storage_slots(info)
        expandable = nil
        info.each_key do |key|
          next unless (match = /\Astoragecontrollername(\d+)\z/.match(key))

          index = match[1]
          type = info["storagecontrollertype#{index}"]
          next if %w{I82078 USB}.include?(type)

          name = info.fetch(key)
          devices = %w{PIIX3 PIIX4 ICH6}.include?(type) ? %w{0 1} : ["0"]
          port_count = Integer(info.fetch("storagecontrollerportcount#{index}"))
          max_ports = Integer(info.fetch("storagecontrollermaxportcount#{index}", port_count))
          expandable ||= [name, port_count] if port_count < max_ports
          port_count.times do |port|
            devices.each do |device|
              medium = slots[[name, port.to_s, device]]
              return [name, port.to_s, device] if medium.nil? || medium == "none"
            end
          end
        end
        if expandable
          name, port = expandable
          vbox("storagectl", uuid, "--name", name, "--portcount", (port + 1).to_s)
          return [name, port.to_s, "0"]
        end

        raise ActionFailed, "VirtualBox VM has no free disk slot for driver.disk_size_mib"
      end

      def storage_slots(info)
        controllers = info.filter_map { |key, value| value if /\Astoragecontrollername\d+\z/.match?(key) }
        info.each_with_object({}) do |(key, value), slots|
          match = /\A"(.+)-(\d+)-(\d+)"\z/.match(key)
          slots[match.captures] = value if match && controllers.include?(match[1])
        end
      end

      def detach_unowned_media(uuid, info, state)
        owned_disks = verified_owned_disks(state)
        storage_slots(info).each do |(controller, port, device), medium|
          next if %w{none emptydrive}.include?(medium)

          id = info[%Q{"#{controller}-ImageUUID-#{port}-#{device}"}]
          next if owned_disks[id] == medium

          vbox("storageattach", uuid, "--storagectl", controller, "--port", port, "--device", device, "--medium", "none")
        end
      end

      def clean_owned_media(state)
        verified_owned_disks(state).each_key do |id|
          vbox("closemedium", "disk", id, "--delete")
        end
      end

      def registered_disks
        vbox("list", "hdds").split(/\n\s*\n/).filter_map do |entry|
          id = entry[/^UUID:[ \t]+([0-9a-f-]+)$/, 1]
          path = entry[/^Location:[ \t]+(.+)$/, 1]
          [id, path] if id && path && entry.match?(/^Parent UUID:[ \t]+base$/)
        end.to_h
      end

      def verified_owned_disks(state)
        identities = state[:virtualbox_media_identities] || {}
        return {} if identities.empty?

        registered_disks.select do |id, path|
          identity = identities[id.to_sym]
          identity && identity == disk_identity(path)
        end
      end

      def disk_identity(path)
        return unless File.realpath(path) == path

        stat = File.stat(path)
        [path, stat.dev, stat.ino] if stat.file?
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end

      def reset_missing_vm(state)
        %i{virtualbox_token virtualbox_uuid virtualbox_owned_media virtualbox_media_identities
           virtualbox_blank_disk virtualbox_blank_disk_uuid virtualbox_disk_size_mib}.each { |key| state.delete(key) }
        prepare_state(state)
      end

      def prepare_state(state)
        return if state[:virtualbox_token]

        state[:virtualbox_token] = SecureRandom.uuid
        state[:virtualbox_name] = "kitchen-#{instance.name}-#{state[:virtualbox_token]}"
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
        vbox("list", "vms").each_line do |line|
          entry = /\A"(.*)" \{([0-9a-f-]+)\}\s*\z/i.match(line)
          next unless entry

          name, uuid = entry.captures
          return uuid if state[:virtualbox_uuid] ? uuid == state[:virtualbox_uuid] : name == state[:virtualbox_name]
        end
        nil
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
        forwarding = info.select { |key, _| key.start_with?("Forwarding(") }.values
        if info.fetch("VMState") == "running"
          rule = forwarding.find { |value| value.start_with?("kitchen-ssh,tcp,127.0.0.1,") }
          raise ActionFailed, "Running VirtualBox VM is missing its Kitchen SSH forwarding rule" unless rule

          state[:port] = Integer(rule.split(",").fetch(3))
        else
          forwarding.each do |rule|
            vbox("modifyvm", uuid, "--nat-pf1", "delete=#{rule.split(",").first}")
          end
          TCPServer.open("127.0.0.1", 0) { |socket| state[:port] = socket.addr[1] }
          vbox("modifyvm", uuid, "--nic1", "nat", "--nat-pf1", "kitchen-ssh,tcp,127.0.0.1,#{state[:port]},,#{instance.transport[:port] || 22}")
          vbox("startvm", uuid, "--type", "headless")
        end
        state[:hostname] = "127.0.0.1"
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

      def vbox(*arguments, **options)
        command(config[:vboxmanage], *arguments, **options)
      end

      def command(*arguments, **options)
        debug("Running #{arguments.first(3).inspect}")
        process = Mixlib::ShellOut.new(*arguments, timeout: 600, **options)
        process.run_command
        process.error!
        process.stdout
      rescue Mixlib::ShellOut::ShellCommandFailed, Mixlib::ShellOut::CommandTimeout, SystemCallError => e
        raise ActionFailed, e.message
      end
    end
  end
end
