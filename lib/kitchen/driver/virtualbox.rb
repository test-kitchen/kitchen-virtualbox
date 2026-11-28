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
require "rexml/document" unless defined?(REXML::Document)
require "securerandom" unless defined?(SecureRandom)
require "socket" unless defined?(Socket)
require "tempfile" unless defined?(Tempfile)
require "time" unless defined?(Time.zone_offset)
require "tmpdir" unless defined?(Dir.mktmpdir)
require_relative "virtualbox/package"

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
      default_config :source_vm
      default_config :source_snapshot
      default_config :vboxmanage, "VBoxManage"
      default_config :insert_key, true
      default_config :port_forward
      default_config :private_network
      default_config :private_address
      default_config :synced_folders, []
      default_config :disk_size_mib

      # VBoxManage's guest limits on the 64-bit hosts supported by VirtualBox 7.2.
      HARDWARE_LIMITS = { cpus: (1..64), memory: (4..2_097_152) }.freeze
      private_constant :HARDWARE_LIMITS

      UUID_PATTERN = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/
      MANAGED_SHARE_NAME_PATTERN = /\Akitchen-[0-9a-f]{16}\z/
      private_constant :MANAGED_SHARE_NAME_PATTERN

      include Box::Source
      include VirtualboxPackage

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
        validate_hardware
        source = config[:source_vm]
        snapshot = config[:source_snapshot]
        validate_clone_source(source, snapshot)
        size = config[:disk_size_mib]
        unless size.nil? || (size.is_a?(Integer) && size > 0)
          raise ActionFailed, "VirtualBox driver.disk_size_mib must be a positive integer"
        end

        forward_ports = configured_forward_ports
        private_network, private_address = private_network_settings
        folders = synced_folders
        prepare_state(state)
        if source.nil? && state[:virtualbox_uuid] == state[:virtualbox_token]
          raise ActionFailed, "Run kitchen destroy before switching from a registered VirtualBox clone to a box."
        end

        verify_clone_request(source, snapshot, state)
        uuid = if state[:virtualbox_restore_pending]
                 managed_vm_info(state).fetch("UUID")
               else
                 registered_uuid(state)
               end
        unless uuid
          if source && state.key?(:virtualbox_media_identities)
            raise ActionFailed, "The registered VirtualBox clone is missing. Run kitchen destroy before recreating it."
          end

          reset_missing_vm(state) if state[:virtualbox_uuid] && !source
          uuid = source ? clone_vm(source, snapshot, state) : import_vm(state)
        end
        unless state.key?(:virtualbox_media_identities) || state[:virtualbox_restore_pending]
          directory = File.realpath(vm_directory(state))
          paths = storage_slots(vm_info(uuid)).values
          state[:virtualbox_media_identities] = registered_disks.filter_map do |id, path|
            next unless paths.include?(path) && path.start_with?("#{directory}/")

            identity = disk_identity(path)
            [id.to_sym, identity] if identity
          end.to_h
        end
        record_linked_clone_media(uuid, state) if state[:virtualbox_linked_clone]
        state[:virtualbox_uuid] = uuid
        checkpoint(state) unless state[:virtualbox_restore_pending]
        attach_blank_disk(uuid, state, size) if size && !state[:virtualbox_restore_pending]
        with_linked_clone_artifacts(uuid, state) do
          ensure_running(uuid, state, forward_ports, private_network, private_address, folders)
        end
        configure_ssh(uuid, state)
        connection = instance.transport.connection(state.except(:virtualbox_restore_pending))
        connection.wait_until_ready
        configure_private_address(connection, uuid, private_address) if private_address
        state.delete(:virtualbox_restore_pending)
      end

      def destroy(state)
        return unless state[:virtualbox_token]

        directory = vm_directory(state)
        uuid = registered_uuid(state)
        verify_clone_destination(state, directory) unless uuid
        managed_vm_info(state) if uuid && state[:virtualbox_restore_pending]
        if uuid
          snapshots = vbox("snapshot", uuid, "list", "--machinereadable", returns: [0, 1]).strip
          unless snapshots == "This machine does not have any snapshots"
            raise ActionFailed, "Cannot destroy the VirtualBox VM while snapshot media ownership is unverified"
          end

          if state[:virtualbox_linked_clone]
            record_linked_clone_media(uuid, state)
            record_linked_clone_artifacts(uuid, state) unless state.key?(:virtualbox_linked_artifacts)
            disks = hard_disks
            state.fetch(:virtualbox_linked_media).each do |chain, identity|
              verify_linked_disk(chain, identity, directory, disks)
            end
            state[:virtualbox_destroying] = true
            checkpoint(state)
          end
          info = vm_info(uuid)
          tracked_config = linked_config_artifacts(info["CfgFile"], state) if state[:virtualbox_linked_clone]
          status = info.fetch("VMState")
          case status
          when "running", "paused", "stuck"
            vbox("controlvm", uuid, "poweroff")
          when "saved"
            vbox("discardstate", uuid)
          end
          # Linked clones share a disk chain with their source.
          if state[:virtualbox_linked_clone]
            detach_linked_clone_owned_disks(uuid, info, state)
            clean_owned_media(state)
            vbox("unregistervm", uuid)
            refresh_linked_config_artifacts(uuid, state, tracked_config)
          else
            detach_unowned_media(uuid, info, state)
            vbox("unregistervm", uuid, "--delete")
          end
        end
        clean_owned_media(state)
        close_linked_clone_media(directory, state) if state[:virtualbox_linked_clone]
        FileUtils.rm_f(File.join(directory, "ssh_key"))
        invalidate_key_history(state)
        Dir.rmdir(directory) if File.directory?(directory) && Dir.empty?(directory)
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
        checks = [-> { vbox("list", "vms") }, method(:validate_vm_source)]
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

        verify_snapshot_shared_folders(settings.elements["/VirtualBox/Machine"], entry)
      rescue REXML::ParseException, SystemCallError
        raise ActionFailed, "Could not read VirtualBox snapshot settings for #{instance.name}"
      end

      def verify_snapshot_shared_folders(machine, snapshot)
        path = "Hardware/SharedFolders/SharedFolder"
        snapshot.get_elements(path).each do |folder|
          name = folder.attributes["name"]
          next unless name&.match?(MANAGED_SHARE_NAME_PATTERN)

          # The current ownership list cannot establish who owned an older mapping.
          current = machine.get_elements(path).select { |mapping| mapping.attributes["name"] == name }
          next if current.one? && current.first.attributes.to_h == folder.attributes.to_h

          raise ActionFailed, "Snapshot would restore an ambiguous VirtualBox shared folder: #{name}"
        end
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

      def validate_vm_source
        source = config[:source_vm]
        validate_clone_source(source, config[:source_snapshot])
        source.nil? ? validate_box : powered_off_source_uuid(source)
      end

      def validate_clone_source(source, snapshot)
        unless snapshot.nil? || (snapshot.is_a?(String) && !snapshot.strip.empty? && source && config[:box].nil?)
          raise ActionFailed, "Set driver.source_snapshot to an existing snapshot name or UUID with driver.source_vm and without driver.box"
        end

        validate_source_vm(source)
      end

      def validate_source_vm(source)
        unless source.nil? || (source.is_a?(String) && !source.strip.empty? && config[:box].nil?)
          raise ActionFailed, "Set driver.source_vm to a registered VirtualBox VM name or UUID without driver.box"
        end
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

      def detach_linked_clone_owned_disks(uuid, info, state)
        owned_disks = verified_owned_disks(state)
        storage_slots(info).each do |(controller, port, device), path|
          id = info[%Q{"#{controller}-ImageUUID-#{port}-#{device}"}]
          next unless owned_disks.key?(id) && owned_disks[id] == path

          vbox("storageattach", uuid, "--storagectl", controller, "--port", port, "--device", device, "--medium", "none")
        end
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

      def with_linked_clone_artifacts(uuid, state)
        return yield unless state[:virtualbox_linked_clone]

        record_linked_clone_artifacts(uuid, state) unless state.key?(:virtualbox_linked_artifacts)
        tracked = linked_config_artifacts(vm_info(uuid)["CfgFile"], state)
        begin
          yield
        ensure
          refresh_linked_config_artifacts(uuid, state, tracked)
          unless state[:virtualbox_linked_start_attempted]
            state[:virtualbox_linked_start_attempted] = true
            record_linked_clone_artifacts(uuid, state)
          end
        end
      end

      def record_linked_clone_artifacts(uuid, state)
        directory = vm_directory(state)
        info = vm_info(uuid)
        files = []
        if (config_file = info["CfgFile"])
          files.push(config_file, "#{config_file}-prev", config_file.sub(/\.vbox\z/, ".nvram"))
        end
        if (logs = info["LogFldr"]) && inside_directory?(canonical_disk_path(logs), directory)
          files.concat(Dir.glob("VBox.log{,.[0-9]*}", base: logs).map { |name| File.join(logs, name) })
        end

        artifacts = Array(state[:virtualbox_linked_artifacts]).to_h
        files.each do |file|
          path = canonical_disk_path(file)
          next unless inside_directory?(path, directory) && File.file?(file) && !File.symlink?(file)

          artifacts[path] ||= disk_file_identity(path)
          parent = File.dirname(path)
          while inside_directory?(parent, directory)
            artifacts[parent] ||= disk_file_identity(parent)
            parent = File.dirname(parent)
          end
        end
        state.fetch(:virtualbox_linked_media).each do |chain, _|
          parent = File.dirname(chain.first[1])
          artifacts[parent] = disk_file_identity(parent) if inside_directory?(parent, directory)
        end
        state[:virtualbox_linked_artifacts] = artifacts.to_a
        checkpoint(state)
      end

      def linked_config_artifacts(config_path, state)
        return [] unless config_path

        canonical = canonical_disk_path(config_path)
        return [] unless canonical

        config_paths = [canonical, "#{canonical}-prev"]
        Array(state[:virtualbox_linked_artifacts]).select do |path, identity|
          config_paths.include?(path) && canonical_disk_path(path) == path && disk_file_identity(path) == identity
        end
      end

      def refresh_linked_config_artifacts(uuid, state, tracked)
        return if tracked.empty?

        artifacts = state.fetch(:virtualbox_linked_artifacts).to_h
        tracked.each do |path, identity|
          next unless canonical_disk_path(path) == path && File.file?(path)

          current = disk_file_identity(path)
          next if current == identity

          config = REXML::Document.new(File.binread(path))
          machine = config.elements["/VirtualBox/Machine"]
          artifacts[path] = current if machine && machine.attributes["uuid"]&.casecmp?("{#{uuid}}")
        rescue REXML::ParseException, SystemCallError
          next
        end
        state[:virtualbox_linked_artifacts] = artifacts.to_a
        checkpoint(state)
      end

      def remove_linked_clone_artifacts(directory, state)
        artifacts = Array(state[:virtualbox_linked_artifacts])
        registered = hard_disks.values.flat_map { |path, _, location| [path, location] }

        artifacts.sort_by { |path, _| -path.length }.each do |path, identity|
          next unless inside_directory?(path, directory) && canonical_disk_path(path) == path
          next if registered.include?(path) || disk_file_identity(path) != identity

          if File.file?(path)
            File.unlink(path)
          elsif File.directory?(path) && Dir.empty?(path)
            Dir.rmdir(path)
          end
        end
      end

      def inside_directory?(path, directory)
        path&.start_with?("#{directory}/")
      end

      def verify_clone_request(source, snapshot, state)
        previous = state[:virtualbox_clone_request]
        legacy_full_clone = !previous && state.key?(:virtualbox_media_identities) &&
          state[:virtualbox_token] == state[:virtualbox_uuid]
        if state[:virtualbox_destroying] || (previous && previous != [source, snapshot]) || (legacy_full_clone && snapshot)
          raise ActionFailed, "Run kitchen destroy before recreating the VirtualBox instance with this configuration"
        end
      end

      def prepare_state(state)
        return if state[:virtualbox_token]

        state[:virtualbox_token] = SecureRandom.uuid
        state[:virtualbox_name] = vm_name(state)
        state[:virtualbox_uuid] = state[:virtualbox_token] if config[:source_vm]
        checkpoint(state)
      end

      def checkpoint(state)
        state[:virtualbox_restore_pending] ? checkpoint_restore(state) : state_file.write(state)
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

        parent = File.dirname(state_file.path)
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

      def powered_off_source_uuid(source)
        vms = registered_vms
        source_vm = vms.find { |_, uuid| uuid.casecmp?(source) } || vms.find { |name, _| name == source }
        raise ActionFailed, "VirtualBox source VM is not registered: #{source}" unless source_vm

        source_uuid = source_vm.last
        status = vm_info(source_uuid).fetch("VMState")
        unless status == "poweroff"
          raise ActionFailed, "VirtualBox source VM #{source.inspect} must be powered off (current state: #{status})"
        end

        source_uuid
      end

      def verify_clone_destination(state, directory)
        return unless state[:virtualbox_uuid] == state[:virtualbox_token] && !state.key?(:virtualbox_media_identities)
        return unless File.directory?(directory) && !Dir.empty?(directory)

        raise ActionFailed, "VirtualBox left files before registering the clone. Inspect and clear #{directory} before retrying."
      end

      def clone_vm(source, snapshot, state)
        source_uuid = powered_off_source_uuid(source)
        clone_uuid = state.fetch(:virtualbox_token)
        state[:virtualbox_uuid] = clone_uuid
        state[:virtualbox_clone_request] ||= [source, snapshot]
        state[:virtualbox_linked_clone] = !snapshot.nil?
        state[:virtualbox_existing_disks] ||= hard_disks.keys if snapshot
        checkpoint(state)
        directory = vm_directory(state)
        verify_clone_destination(state, directory)
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
        validate_box_path(source)

        checkpoint(state) if state.delete(:virtualbox_uuid)
        directory = vm_directory(state)
        FileUtils.mkdir_p(directory, mode: 0o700)
        invalidate_key_history(state)
        Dir.mktmpdir("box-", directory) do |staging|
          Box::LocalArchive.new(source, provider: "virtualbox").extract(staging) { |*args| command(*args) }
          appliance = File.join(staging, "box.ovf")
          unless File.file?(appliance) && !File.symlink?(appliance)
            raise ActionFailed, "VirtualBox box is missing a regular box.ovf: #{source}"
          end

          vbox("import", appliance, "--options", "importtovdi", "--vsys", "0", "--vmname", state.fetch(:virtualbox_name), "--basefolder", directory, *hardware_options)
        end
        uuid = registered_uuid(state) || raise(ActionFailed, "VirtualBox did not register #{state[:virtualbox_name]}")
        File.write(key_history_path(state), uuid, mode: "wx", perm: 0o600)
        uuid
      rescue Box::LocalArchive::InvalidBox => e
        raise ActionFailed, e.message
      end

      def hardware_options
        HARDWARE_LIMITS.keys.flat_map do |setting|
          config[setting] ? ["--#{setting}", config[setting].to_s] : []
        end
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
        host_port, forwarded_guest_port = forward_ports
        forward_rule = "kitchen-forward,tcp,127.0.0.1,#{host_port},,#{forwarded_guest_port}" if host_port
        info = vm_info(uuid)
        if state[:virtualbox_linked_clone] && info.fetch("VMState") == "saved"
          raise ActionFailed, "Linked clone has a saved runtime state. Run kitchen destroy and choose a snapshot taken while the source was powered off."
        end

        actual_network = info["intnet2"] if info["nic2"] == "intnet"
        verify_private_settings(state, actual_network, private_network, private_address)
        extra_adapters = info.keys.grep(/\Anic[3-8]\z/).reject { |key| info[key] == "none" }
        recovering = state[:virtualbox_restore_pending]
        guest_port = instance.transport[:port] || 22
        if info.fetch("VMState") == "running"
          forwarding = forwarding_rules(info)
          rule = forwarding.find { |value| value.start_with?("kitchen-ssh,tcp,127.0.0.1,") }
          raise ActionFailed, "Running VirtualBox VM is missing its Kitchen SSH forwarding rule" unless rule

          port = Integer(rule.split(",").fetch(3))
          if recovering && (state[:port] != port || info["nic1"] != "nat" || rule != "kitchen-ssh,tcp,127.0.0.1,#{port},,#{guest_port}")
            raise ActionFailed, "Shut down the restored VirtualBox VM before running kitchen create"
          end

          actual_forward = forwarding.find { |value| value.start_with?("kitchen-forward,") }
          private_mismatch = private_network && (actual_network != private_network || !extra_adapters.empty?)
          if actual_forward != forward_rule || private_mismatch
            raise ActionFailed, "Running VirtualBox VM has different networking settings. Run kitchen destroy and then kitchen create."
          end

          state[:port] = port
        else
          if recovering && info["VMState"] != "poweroff"
            raise ActionFailed, "Shut down the restored VirtualBox VM before running kitchen create"
          end

          state[:port] = ssh_host_port(host_port)
          # Registered-source clones use the Kitchen token as their VM UUID.
          if uuid == state[:virtualbox_token]
            isolate_clone(uuid, info, Array(state[:virtualbox_managed_shares]),
              keep_private_adapter: private_network && actual_network == private_network)
            info = vm_info(uuid)
          end
          configure_shared_folders(uuid, state, folders, info)
          forwarding_rules(info).each do |existing_rule|
            vbox("modifyvm", uuid, "--nat-pf1", "delete", existing_rule.split(",").first)
          end
          options = ["--nic1", "nat", "--nat-pf1", "kitchen-ssh,tcp,127.0.0.1,#{state[:port]},,#{guest_port}"]
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
        unless info.fetch("VMState") == "running"
          checkpoint_restore(state) if recovering
          vbox("startvm", uuid, "--type", "headless")
        end
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

      def forwarding_rules(info)
        info.select { |key, _| key.start_with?("Forwarding(") }.values
      end

      def isolate_clone(uuid, info, owned_shares, keep_private_adapter:)
        options = %w{--vrde off --clipboard-mode disabled --drag-and-drop disabled
          --usb-ohci off --usb-ehci off --usb-xhci off --nic-trace1 off --nic1 nat --cable-connected1 on}
        info.each do |key, value|
          if (adapter = /\Anic([0-9]+)\z/.match(key))
            next if key == "nic2" && keep_private_adapter

            options.push("--#{key}", "none") if adapter[1].to_i > 1 && value != "none"
          elsif key.start_with?("SharedFolderNameMachineMapping") && !owned_shares.include?(value)
            vbox("sharedfolder", "remove", uuid, "--name=#{value}")
          end
        end
        vbox("modifyvm", uuid, *options, *hardware_options)
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
        # Guest control can change authorized_keys even if it reports failure.
        invalidate_key_history(state)
        state[:virtualbox_key_injected] = true
        checkpoint(state)
        state[:ssh_key] = Box::SshBootstrap.install(vm_directory(state), runner: method(:command)) do |arguments|
          install_guest_key(uuid, user, arguments)
        end
        state[:username] = user
        state[:virtualbox_generated_key] = true
        state[:virtualbox_generated_key_user] = true
      end

      def key_history_path(state)
        File.join(vm_directory(state), "no-kitchen-key")
      end

      def invalidate_key_history(state)
        File.delete(key_history_path(state))
      rescue Errno::ENOENT
        nil
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
