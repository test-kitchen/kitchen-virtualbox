# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "fileutils" unless defined?(FileUtils)
require "kitchen"
require "kitchen/box/local_archive"
require "kitchen/box/source"
require "kitchen/box/ssh_bootstrap"
require "kitchen/state_file"
require "mixlib/shellout" unless defined?(Mixlib::ShellOut)
require "rexml/document" unless defined?(REXML::Document)
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

      UUID_PATTERN = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/.freeze

      include Box::Source

      module RestoreTransportGuard
        def connection(state, &block)
          if state[:virtualbox_restore_pending]
            raise ActionFailed, "Run kitchen create before connecting to the restored VirtualBox VM"
          end

          super
        end
      end

      def finalize_config!(instance)
        super
        instance.transport.singleton_class.prepend(RestoreTransportGuard)
        self
      end

      def create(state)
        prepare_state(state)
        uuid = if state[:virtualbox_restore_pending]
                 managed_vm_info(state).fetch("UUID")
               else
                 registered_uuid(state) || import_vm(state)
               end
        state[:virtualbox_uuid] = uuid
        checkpoint(state) unless state[:virtualbox_restore_pending]
        ensure_running(uuid, state)
        configure_ssh(uuid, state)
        connection_state = state.except(:virtualbox_restore_pending)
        instance.transport.connection(connection_state).wait_until_ready
        state.delete(:virtualbox_restore_pending)
      end

      def destroy(state)
        return unless state[:virtualbox_token]

        uuid = registered_uuid(state)
        managed_vm_info(state) if uuid && state[:virtualbox_restore_pending]
        if uuid
          status = vm_info(uuid).fetch("VMState")
          case status
          when "running", "paused", "stuck"
            vbox("controlvm", uuid, "poweroff")
          when "saved"
            vbox("discardstate", uuid)
          end
          vbox("unregistervm", uuid, "--delete")
        end
        directory = vm_directory(state)
        FileUtils.remove_entry_secure(directory) if File.exist?(directory)
        release_box_source(state)
      end

      def restore_snapshot(snapshot)
        snapshot = snapshot.to_s.downcase
        raise ActionFailed, "Provide a VirtualBox snapshot UUID" unless UUID_PATTERN.match?(snapshot)

        state = state_file.read
        info = managed_vm_info(state)
        raise ActionFailed, "The managed VirtualBox VM must be powered off before restoring a snapshot" unless info["VMState"] == "poweroff"

        verify_offline_snapshot(info.fetch("CfgFile"), snapshot)

        %i{hostname port last_action}.each { |key| state.delete(key) }
        state[:virtualbox_restore_pending] = true
        checkpoint_restore(state)
        vbox("snapshot", info.fetch("UUID"), "restore", snapshot)
      end

      private

      def managed_vm_info(state)
        uuid = state[:virtualbox_uuid]
        unless uuid.is_a?(String) && UUID_PATTERN.match?(uuid) && state[:virtualbox_token]
          raise ActionFailed, "No Kitchen-managed VirtualBox VM recorded for #{instance.name}"
        end

        info = vm_info(uuid)
        unless info["UUID"] == uuid && info["name"] == vm_name(state) && managed_config_path?(state, info["CfgFile"])
          raise ActionFailed, "Could not verify the Kitchen-managed VirtualBox VM for #{instance.name}"
        end

        info
      end

      def verify_offline_snapshot(path, snapshot)
        # VBoxManage snapshot showvminfo reports the current VM power state.
        settings = REXML::Document.new(File.binread(path))
        entry = settings.get_elements("//Snapshot").find { |node| node.attributes["uuid"]&.casecmp?("{#{snapshot}}") }
        raise ActionFailed, "Snapshot does not exist on #{instance.name}: #{snapshot}" unless entry
        raise ActionFailed, "Take the VirtualBox snapshot while the guest is powered off" if entry.attributes["stateFile"]
      rescue REXML::ParseException, SystemCallError
        raise ActionFailed, "Could not read VirtualBox snapshot settings for #{instance.name}"
      end

      def managed_config_path?(state, path)
        return false unless path && File.file?(path)

        directory = vm_directory(state)
        File.realpath(directory) == directory && File.realpath(path).start_with?("#{directory}#{File::SEPARATOR}")
      rescue SystemCallError
        false
      end

      def vm_name(state)
        "kitchen-#{instance.name}-#{state.fetch(:virtualbox_token)}"
      end

      def prepare_state(state)
        return if state[:virtualbox_token]

        state[:virtualbox_token] = SecureRandom.uuid
        state[:virtualbox_name] = vm_name(state)
        checkpoint(state)
      end

      def checkpoint(state)
        state_file.write(state)
      end

      def state_file
        StateFile.new(config[:kitchen_root], instance.name)
      end

      def checkpoint_restore(state)
        path = state_file.path
        Tempfile.create(".virtualbox-restore-", File.dirname(path)) do |file|
          file.write(YAML.dump(Util.stringified_hash(state)))
          file.fsync
          File.rename(file.path, path)
        end
      end

      def vm_directory(state)
        token = state.fetch(:virtualbox_token)
        unless token.is_a?(String) && UUID_PATTERN.match?(token)
          raise ActionFailed, "Invalid VirtualBox instance ID in Kitchen state"
        end

        File.join(File.realpath(File.dirname(state_file.path)), "virtualbox-#{token}")
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
        recovering = state[:virtualbox_restore_pending]
        guest_port = instance.transport[:port] || 22
        if info.fetch("VMState") == "running"
          rule = forwarding.find { |value| value.start_with?("kitchen-ssh,tcp,127.0.0.1,") }
          raise ActionFailed, "Running VirtualBox VM is missing its Kitchen SSH forwarding rule" unless rule

          port = Integer(rule.split(",").fetch(3))
          if recovering && (state[:port] != port || info["nic1"] != "nat" || rule != "kitchen-ssh,tcp,127.0.0.1,#{port},,#{guest_port}")
            raise ActionFailed, "Shut down the restored VirtualBox VM before running kitchen create"
          end

          state[:port] = port
        else
          if recovering && info["VMState"] != "poweroff"
            raise ActionFailed, "Shut down the restored VirtualBox VM before running kitchen create"
          end

          forwarding.each do |existing_rule|
            vbox("modifyvm", uuid, "--nat-pf1", "delete", existing_rule.split(",").first)
          end
          TCPServer.open("127.0.0.1", 0) { |socket| state[:port] = socket.addr[1] }
          vbox("modifyvm", uuid, "--nic1", "nat", "--nat-pf1", "kitchen-ssh,tcp,127.0.0.1,#{state[:port]},,#{guest_port}")
          checkpoint_restore(state) if recovering
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
