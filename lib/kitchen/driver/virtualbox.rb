# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "digest" unless defined?(Digest)
require "fileutils" unless defined?(FileUtils)
require "ipaddr" unless defined?(IPAddr)
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
      default_config :port_forward
      default_config :private_network
      default_config :private_address
      default_config :synced_folders, []

      # VBoxManage's guest limits on the 64-bit hosts supported by VirtualBox 7.2.
      HARDWARE_LIMITS = { cpus: (1..64), memory: (4..2_097_152) }.freeze
      private_constant :HARDWARE_LIMITS

      include Box::Source

      def create(state)
        validate_hardware
        forward_ports = configured_forward_ports
        private_network, private_address = private_network_settings
        folders = synced_folders
        prepare_state(state)
        uuid = registered_uuid(state) || import_vm(state)
        state[:virtualbox_uuid] = uuid
        checkpoint(state)
        ensure_running(uuid, state, forward_ports, private_network, private_address, folders)
        configure_ssh(uuid, state)
        connection = instance.transport.connection(state)
        connection.wait_until_ready
        configure_private_address(connection, uuid, private_address) if private_address
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

      def synced_folders
        entries = config[:synced_folders]
        unless entries.is_a?(Array)
          raise ActionFailed, "driver.synced_folders must be a list of host and guest path pairs"
        end

        folders = entries.filter_map { |entry| synced_folder(entry) }
        unless folders.map { |folder| folder[:target] }.uniq.size == folders.size
          raise ActionFailed, "Synced folder guest paths must be unique"
        end

        folders.each { |folder| FileUtils.mkdir_p(folder[:source]) if folder[:create] }
        folders
      rescue SystemCallError => e
        raise ActionFailed, "Could not prepare synced folder: #{e.message}"
      end

      def synced_folder(entry)
        unless entry.is_a?(Array) && (2..3).cover?(entry.size) &&
            entry.first(2).all? { |path| path.is_a?(String) && !path.empty? && !path.match?(/[\x00\r\n]/) }
          raise ActionFailed, "Each synced_folders entry needs a host path, a guest path, and optional YAML options"
        end

        source, target, options = entry
        options = {} if options.nil?
        unless options.is_a?(Hash) && (options.keys - %i{create disabled readonly}).empty? &&
            options.values.all? { |value| [true, false].include?(value) }
          raise ActionFailed, "Synced folder options create, disabled and readonly must be boolean"
        end
        return if options[:disabled]

        unless target.start_with?("/") && (target = File.expand_path(target.sub(%r{\A/+}, "/"))) != "/"
          raise ActionFailed, "Synced folder guest paths must be absolute paths other than /"
        end

        source = File.expand_path(source.gsub("%{instance_name}", instance.name), config[:kitchen_root])
        unless File.directory?(source) || (options[:create] && !File.exist?(source))
          raise ActionFailed, "Synced folder host directory does not exist: #{source}"
        end

        source = canonical_host_path(source)
        state_directory = File.join(File.realpath(config[:kitchen_root]), ".kitchen")
        managed_paths = [state_directory, canonical_host_path(state_directory)].uniq
        if managed_paths.any? { |path| source == path || source.start_with?(File.join(path, "")) }
          raise ActionFailed, "Synced folder host directory must be outside Kitchen's managed .kitchen directory"
        end

        readonly = options.fetch(:readonly, false)
        if !readonly && managed_paths.any? { |path| path.start_with?(File.join(source, "")) }
          raise ActionFailed, "Writable synced folders must not contain Kitchen's managed .kitchen directory"
        end

        unless readonly
          cache_directory = canonical_host_path(Box::Cache.new(config[:box_cache]).root)
          if source == cache_directory || source.start_with?(File.join(cache_directory, "")) ||
              cache_directory.start_with?(File.join(source, ""))
            raise ActionFailed, "Writable synced folders must not overlap Kitchen's box cache"
          end
        end

        { source: source, target: target, readonly: readonly, create: options[:create] }
      end

      def canonical_host_path(path)
        File.realpath(path)
      rescue Errno::ENOENT
        raise if File.symlink?(path)

        File.join(canonical_host_path(File.dirname(path)), File.basename(path))
      end

      def configure_shared_folders(uuid, state, folders, info)
        existing = info.filter_map { |key, value| value if key.start_with?("SharedFolderNameMachineMapping") }
        owned = Array(state[:virtualbox_managed_shares])
        desired = folders.to_h do |folder|
          ["kitchen-#{Digest::SHA256.hexdigest(folder.fetch(:target))[0, 16]}", folder]
        end
        collisions = (existing & desired.keys) - owned
        unless collisions.empty?
          raise ActionFailed, "VirtualBox shared folder name already exists: #{collisions.join(", ")}"
        end
        return if owned.empty? && desired.empty?

        # Save both sets before changing the VM so a partial failure is retryable.
        state[:virtualbox_managed_shares] = owned | desired.keys
        checkpoint(state)
        (existing & owned).each { |name| vbox("sharedfolder", "remove", uuid, "--name=#{name}") }

        desired.each do |name, folder|
          arguments = ["--name=#{name}", "--hostpath=#{folder.fetch(:source)}", "--automount", "--auto-mount-point=#{folder.fetch(:target)}"]
          arguments << "--readonly" if folder.fetch(:readonly)
          vbox("sharedfolder", "add", uuid, *arguments)
        end
        state[:virtualbox_managed_shares] = desired.keys
        checkpoint(state)
      end

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

      def configured_forward_ports
        forward = config[:port_forward]
        return if forward.nil?

        ports = forward.values_at(:host_port, :guest_port) if forward.is_a?(Hash)
        unless ports && ports.all? { |port| port.is_a?(Integer) && (1..65535).cover?(port) }
          raise ActionFailed, "VirtualBox driver.port_forward requires integer host_port and guest_port in 1..65535"
        end

        ports
      end

      def private_network_settings
        network = config[:private_network]
        address = config[:private_address]
        unless network.nil? || (network.is_a?(String) && /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/.match?(network))
          raise ActionFailed, "VirtualBox driver.private_network requires an internal network name using letters, digits, dots, underscores or hyphens"
        end
        return [network, nil] if address.nil?

        unless network && address.is_a?(String) && %r{\A[\d.]+/(?:[1-9]|[12][0-9]|3[0-2])\z}.match?(address) && IPAddr.new(address).ipv4?
          raise ActionFailed, "VirtualBox driver.private_address requires an IPv4 CIDR address and driver.private_network"
        end

        [network, address]
      rescue IPAddr::InvalidAddressError
        raise ActionFailed, "VirtualBox driver.private_address requires a valid IPv4 CIDR address"
      end

      def verify_private_settings(state, actual_network, network, address)
        applied = state.values_at(:virtualbox_private_network, :virtualbox_private_address)
        pending = state[:virtualbox_pending_private_settings]
        # A command may fail before changing the NIC or after VirtualBox has applied it.
        recorded = [applied, pending].compact.find { |settings| actual_network && settings.first == actual_network }
        return if recorded.nil? || recorded == [network, address]

        raise ActionFailed, "VirtualBox VM has different private networking settings. Run kitchen destroy and then kitchen create."
      end

      def ensure_running(uuid, state, forward_ports, private_network, private_address, folders)
        host_port, guest_port = forward_ports
        forward_rule = "kitchen-forward,tcp,127.0.0.1,#{host_port},,#{guest_port}" if host_port
        info = vm_info(uuid)
        actual_network = info["intnet2"] if info["nic2"] == "intnet"
        verify_private_settings(state, actual_network, private_network, private_address)
        extra_adapters = info.keys.grep(/\Anic[3-8]\z/).reject { |key| info[key] == "none" }
        forwarding = info.select { |key, _| key.start_with?("Forwarding(") }.values
        if info.fetch("VMState") == "running"
          rule = forwarding.find { |value| value.start_with?("kitchen-ssh,tcp,127.0.0.1,") }
          raise ActionFailed, "Running VirtualBox VM is missing its Kitchen SSH forwarding rule" unless rule

          actual_forward = forwarding.find { |value| value.start_with?("kitchen-forward,") }
          private_mismatch = private_network && (actual_network != private_network || !extra_adapters.empty?)
          if actual_forward != forward_rule || private_mismatch
            raise ActionFailed, "Running VirtualBox VM has different networking settings. Run kitchen destroy and then kitchen create."
          end

          state[:port] = Integer(rule.split(",").fetch(3))
        else
          configure_shared_folders(uuid, state, folders, info)
          state[:port] = ssh_host_port(host_port)
          forwarding.each do |existing_rule|
            vbox("modifyvm", uuid, "--nat-pf1", "delete", existing_rule.split(",").first)
          end
          options = ["--nic1", "nat", "--nat-pf1", "kitchen-ssh,tcp,127.0.0.1,#{state[:port]},,#{instance.transport[:port] || 22}"]
          options.push("--nat-pf1", forward_rule) if forward_rule
          vbox("modifyvm", uuid, *options)
          if private_network
            state[:virtualbox_pending_private_settings] = [private_network, private_address]
            checkpoint(state)
            adapters = ["--intnet2", private_network, "--nic2", "intnet", "--cable-connected2", "on"]
            extra_adapters.each { |key| adapters.push("--#{key}", "none") }
            vbox("modifyvm", uuid, *adapters)
          end
        end

        state[:hostname] = "127.0.0.1"
        record_private_settings(state, private_network, private_address)
        vbox("startvm", uuid, "--type", "headless") unless info.fetch("VMState") == "running"
      end

      def record_private_settings(state, network, address)
        pending = state.delete(:virtualbox_pending_private_settings)
        return if !pending && state.values_at(:virtualbox_private_network, :virtualbox_private_address) == [network, address]

        if network
          state[:virtualbox_private_network] = network
          state[:virtualbox_private_address] = address
        else
          state.delete(:virtualbox_private_network)
          state.delete(:virtualbox_private_address)
        end
        checkpoint(state)
      end

      def ssh_host_port(forwarded_port)
        TCPServer.open("127.0.0.1", 0) do |socket|
          port = socket.addr[1]
          return port unless forwarded_port

          if port == forwarded_port
            return TCPServer.open("127.0.0.1", 0) { |other| other.addr[1] }
          end

          TCPServer.open("127.0.0.1", forwarded_port, &:close)
          port
        end
      rescue Errno::EADDRINUSE, Errno::EACCES => e
        raise ActionFailed, "Could not bind VirtualBox port forward on 127.0.0.1:#{forwarded_port}: #{e.message}"
      end

      def configure_private_address(connection, uuid, address)
        mac = vm_info(uuid)["macaddress2"]
        unless mac && /\A\h{12}\z/.match?(mac)
          raise ActionFailed, "VirtualBox did not report a MAC address for the private adapter"
        end

        formatted_mac = mac.downcase.scan(/../).join(":")
        connection.execute(<<~SH)
          set -eu
          for device in /sys/class/net/*; do
            [ "$(cat "$device/address")" = "#{formatted_mac}" ] || continue
            iface=${device##*/}
            elevate=
            [ "$(id -u)" -eq 0 ] || elevate="sudo -n"
            $elevate ip link set dev "$iface" up
            $elevate ip -4 address replace #{address} dev "$iface"
            exit 0
          done
          echo "VirtualBox private adapter #{formatted_mac} is missing in the guest" >&2
          exit 1
        SH
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
