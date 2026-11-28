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
require "time" unless defined?(Time.zone_offset)
require "tmpdir" unless defined?(Dir.mktmpdir)

module Kitchen
  module Driver
    class Virtualbox < Base
      kitchen_driver_api_version 2
      plugin_version "0.1.0"

      default_config :box
      default_config :box_manifest
      default_config :box_cache
      default_config :cpus
      default_config :memory
      default_config :vboxmanage, "VBoxManage"
      default_config :insert_key, true

      # VBoxManage's guest limits on the 64-bit hosts supported by VirtualBox 7.2.
      HARDWARE_LIMITS = { cpus: (1..64), memory: (4..2_097_152) }.freeze
      private_constant :HARDWARE_LIMITS

      include Box::Source

      def create(state)
        validate_hardware
        prepare_state(state)
        uuid = registered_uuid(state) || import_vm(state)
        state[:virtualbox_uuid] = uuid
        checkpoint(state)
        ensure_running(uuid, state)
        configure_ssh(uuid, state) unless winrm?
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
          vbox("unregistervm", uuid, "--delete")
        end
        directory = vm_directory(state)
        FileUtils.remove_entry_secure(directory) if File.exist?(directory)
        release_box_source(state)
      end

      def status(state)
        id = state[:virtualbox_uuid]
        unless id || state[:virtualbox_name]
          return status_report(false, "not_created", "No managed VM is recorded for this instance")
        end

        registered = registered_uuid(state)
        unless registered
          return status_report(false, "not_created", "VirtualBox has no matching managed VM", id)
        end

        id = registered
        vm_state = vm_info(id).fetch("VMState") { raise ActionFailed, "VBoxManage did not report VMState for #{id}" }
        status_report(vm_state == "running", vm_state, "VirtualBox reports the VM as #{vm_state}", id)
      rescue ActionFailed => e
        status_report(nil, "unknown", e.message, id)
      end

      def doctor(_state)
        checks = [-> { vbox("list", "vms") }, method(:validate_box)]
        problems = checks.filter_map do |check|
          check.call
          nil
        rescue ActionFailed, UserError => e
          e.message
        end
        problems.each { |problem| warn(problem) }
        !problems.empty?
      end

      private

      def validate_hardware
        HARDWARE_LIMITS.each do |setting, range|
          value = config[setting]
          next if value.nil?

          unless value.is_a?(Integer) && value > 0
            raise ActionFailed, "driver.#{setting} must be a positive integer"
          end

          unless range.cover?(value)
            raise ActionFailed, "driver.#{setting} must be within VirtualBox's supported range (#{range})"
          end
        end
      end

      def status_report(live, state, message, id = nil)
        { live: live, state: state, source: "driver", resource_id: id,
          message: message, checked_at: Time.now.utc.iso8601 }
      end

      def validate_box
        box = config[:box]
        if box.is_a?(Hash)
          manifest = config[:box_manifest] || ENV[Box::Catalog::ENV_KEY]
          manifest = File.expand_path(manifest, config[:kitchen_root]) unless manifest.to_s.empty?
          catalog = Box::Catalog.new(manifest)
          entry = catalog.find(name: box[:name], version: box[:version], provider: "virtualbox")
          Box::Cache.new(config[:box_cache]).validate_destination(catalog, entry)
          catalog.verify(entry)
        else
          raise ActionFailed, "Set driver.box to a local path or a map with name and an exact version" unless box.is_a?(String) && !box.empty?

          path = File.expand_path(box, config[:kitchen_root])
          validate_box_path(path)
        end
      end

      def validate_box_path(path)
        return if File.file?(path) && File.readable?(path) && File.extname(path) == ".box"

        raise ActionFailed, "VirtualBox driver.box must point to a readable local .box archive: #{path}"
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
        validate_box_path(source)

        checkpoint(state) if state.delete(:virtualbox_uuid)
        directory = vm_directory(state)
        FileUtils.mkdir_p(directory, mode: 0o700)
        Dir.mktmpdir("box-", directory) do |staging|
          Box::LocalArchive.new(source, provider: "virtualbox").extract(staging) { |*args| command(*args) }
          appliance = File.join(staging, "box.ovf")
          unless File.file?(appliance) && !File.symlink?(appliance)
            raise ActionFailed, "VirtualBox box is missing a regular box.ovf: #{source}"
          end

          hardware = HARDWARE_LIMITS.keys.flat_map do |setting|
            config[setting] ? ["--#{setting}", config[setting].to_s] : []
          end
          vbox("import", appliance, "--vsys", "0", "--vmname", state.fetch(:virtualbox_name), "--basefolder", directory, *hardware)
        end
        registered_uuid(state) || raise(ActionFailed, "VirtualBox did not register #{state[:virtualbox_name]}")
      rescue Box::LocalArchive::InvalidBox => e
        raise ActionFailed, e.message
      end

      def ensure_running(uuid, state)
        info = vm_info(uuid)
        winrm = winrm?
        if winrm && info.any? { |key, value| /\Anic(?:[2-9]|[1-9]\d+)\z/.match?(key) && value != "none" }
          raise ActionFailed, "VirtualBox WinRM requires a box with only its first network adapter enabled"
        end

        rule_name = winrm ? "kitchen-winrm" : "kitchen-ssh"
        guest_port = instance.transport[:port] || 22
        rule_prefix = "#{rule_name},tcp,127.0.0.1,"
        forwarding = info.select { |key, _| key.start_with?("Forwarding(") }.values
        if info.fetch("VMState") == "running"
          rule = forwarding.find { |value| value.start_with?(rule_prefix) }
          unless rule && (!winrm || rule.end_with?(",,#{guest_port}"))
            raise ActionFailed, "Running VirtualBox VM is missing its #{rule_name} forwarding rule for the configured transport. Run kitchen destroy before changing the transport or its guest port."
          end

          state[:port] = Integer(rule.split(",").fetch(3))
        else
          forwarding.each do |imported_rule|
            vbox("modifyvm", uuid, "--nat-pf1", "delete=#{imported_rule.split(",").first}")
          end
          TCPServer.open("127.0.0.1", 0) { |socket| state[:port] = socket.addr[1] }
          vbox("modifyvm", uuid, "--nic1", "nat", "--nat-pf1", "#{rule_prefix}#{state[:port]},,#{guest_port}")
          vbox("startvm", uuid, "--type", "headless")
        end
        state[:hostname] = "127.0.0.1"
      end

      def winrm?
        defined?(Kitchen::Transport::Winrm) && instance.transport.is_a?(Kitchen::Transport::Winrm)
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
