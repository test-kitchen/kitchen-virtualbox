# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "json" unless defined?(JSON)
require "rexml/document" unless defined?(REXML::Document)

module Kitchen
  module Driver
    module VirtualboxPackage
      def package(state)
        unless state[:virtualbox_token] && state[:virtualbox_uuid] && state[:virtualbox_name]
          raise ActionFailed, "Create the Kitchen instance before packaging it"
        end

        refuse_injected_key(state)
        output = File.join(config[:kitchen_root], "#{instance.name}.box")
        raise ActionFailed, "Package already exists: #{output}" if File.exist?(output) || File.symlink?(output)

        uuid = registered_uuid(state)
        unless uuid
          raise ActionFailed, "Create the Kitchen instance before packaging it"
        end

        components = package_components(uuid, state)
        Dir.mktmpdir(".virtualbox-package-", File.dirname(output)) do |stage|
          appliance = File.join(stage, "box.ovf")
          vbox("export", uuid, "--output", appliance, "--ovf20")
          files = validate_appliance(appliance, components)
          vbox("import", appliance, "--dry-run")

          File.write(File.join(stage, "metadata.json"), JSON.generate(provider: "virtualbox"))
          archive = File.join(stage, "package.box")
          command("/usr/bin/tar", "-cf", archive, "-C", stage, "metadata.json", "box.ovf", *files)
          File.chmod(0o600, archive)
          verify_package_source(uuid, state)
          File.link(archive, output)
        end
        info("Packaged #{instance.name} to #{output}")
        output
      rescue Errno::EEXIST
        raise ActionFailed, "Package already exists: #{output}"
      rescue SystemCallError, REXML::ParseException => e
        raise ActionFailed, "Could not package the VirtualBox VM: #{e.message}"
      end

      private

      def refuse_injected_key(state)
        if state[:virtualbox_generated_key] || state[:virtualbox_key_injected] || key_file_present?(state)
          raise ActionFailed, "Cannot safely remove the Kitchen-injected SSH key from a stopped VM. " \
            "Create a fresh instance with driver.insert_key disabled and supply your own SSH credentials."
        end
      end

      def key_file_present?(state)
        key = File.join(vm_directory(state), "ssh_key")
        File.exist?(key) || File.symlink?(key)
      end

      def stopped_package_vm(uuid, state)
        details = vm_info(uuid)
        unless details["name"] == state[:virtualbox_name] && details["VMState"] == "poweroff"
          raise ActionFailed, "Shut down the managed VirtualBox VM before packaging it"
        end

        details
      end

      def verify_package_source(uuid, state)
        current = StateFile.new(config[:kitchen_root], instance.name).read
        unless current.values_at(:virtualbox_token, :virtualbox_uuid, :virtualbox_name) ==
            state.values_at(:virtualbox_token, :virtualbox_uuid, :virtualbox_name)
          raise ActionFailed, "VirtualBox instance changed while packaging it"
        end

        refuse_injected_key(current)
        stopped_package_vm(uuid, current)
      end

      def package_components(uuid, state)
        details = stopped_package_vm(uuid, state)
        directory = File.realpath(vm_directory(state))
        controllers = details.filter_map { |key, value| value if key.match?(/\Astoragecontrollername\d+\z/) }
        disks = controllers.flat_map do |controller|
          slot = /\A"#{Regexp.escape(controller)}-\d+-\d+"\z/
          details.filter_map { |key, value| value if slot.match?(key) && !%w{none emptydrive}.include?(value) }
        end
        nvram = details["NvramFile"]
        media = disks + [details["CfgFile"], nvram].compact.reject(&:empty?)
        if disks.empty? || media.any? { |path| !File.file?(path) || !File.realpath(path).start_with?("#{directory}/") } ||
            disks.any? { |path| !%w{.vmdk .vdi .vhd .hdd}.include?(File.extname(path).downcase) }
          raise ActionFailed, "Package requires VM-owned disks and no mounted optical media"
        end
        unless disks.all? { |path| vbox("showmediuminfo", "disk", path).match?(/^Parent UUID:\s+base$/) }
          raise ActionFailed, "Package requires standalone VirtualBox disks without snapshot or clone parents"
        end
        if details.keys.any? { |key| key.start_with?("SharedFolderName") }
          raise ActionFailed, "Remove VirtualBox shared folders before packaging the VM"
        end

        components = { ".vmdk" => disks.length }
        components[".nvram"] = 1 unless nvram.to_s.empty?
        components
      end

      def validate_appliance(appliance, components)
        unless File.file?(appliance) && !File.symlink?(appliance)
          raise ActionFailed, "VirtualBox export did not produce a regular box.ovf"
        end

        document = REXML::Document.new(File.read(appliance))
        references = document.elements.to_a("/Envelope/References/File")
        files = references.map { |file| file.attributes["ovf:href"].to_s }
        valid = files.uniq == files && files.map { |file| File.extname(file) }.tally == components &&
          references.all? { |file| valid_export_file?(appliance, file) }
        raise ActionFailed, "VirtualBox export is missing disk or firmware data" unless valid

        files
      end

      def valid_export_file?(appliance, reference)
        filename = reference.attributes["ovf:href"]
        return false unless filename&.match?(/\A[\w.-]+\.(?:vmdk|nvram)\z/) && !filename.start_with?("-")

        path = File.join(File.dirname(appliance), filename)
        size = reference.attributes["ovf:size"]
        File.file?(path) && !File.symlink?(path) && File.size?(path) && (size.nil? || File.size(path).to_s == size)
      end
    end
  end
end
