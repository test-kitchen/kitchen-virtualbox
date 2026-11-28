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
        history = key_history_path(state)
        if state[:virtualbox_generated_key] || state[:virtualbox_key_injected] || key_file_present?(state) ||
            File.symlink?(history) || !File.file?(history) || File.read(history, 37) != state[:virtualbox_uuid]
          raise ActionFailed, "Cannot safely remove the Kitchen-injected SSH key from a stopped VM. " \
            "Import a fresh instance with driver.box and driver.insert_key disabled, and supply your own SSH credentials."
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
        package_components(uuid, current)
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
        if disks.empty? || media.any? { |path| !File.file?(path) || !File.realpath(path).start_with?("#{directory}/") }
          raise ActionFailed, "Package requires VM-owned disks and no mounted optical media"
        end
        unless disks.uniq == disks && disks.all? { |path| standalone_package_disk?(path, uuid) }
          raise ActionFailed, "Package requires standalone VDI disks attached only to the source VM"
        end
        if details.keys.any? { |key| key.start_with?("SharedFolderName") }
          raise ActionFailed, "Remove VirtualBox shared folders before packaging the VM"
        end

        components = { ".vmdk" => disks.length }
        components[".nvram"] = 1 unless nvram.to_s.empty?
        components
      end

      def standalone_package_disk?(path, uuid)
        return false unless File.extname(path).downcase == ".vdi" && !File.symlink?(path) && File.stat(path).nlink == 1

        medium = vbox("showmediuminfo", "disk", path)
        medium.match?(/^Storage format:[ \t]+vdi$/i) &&
          medium.match?(/^Parent UUID:[ \t]+base$/) &&
          medium.match?(/^Type:[ \t]+normal(?: \(base\))?$/) &&
          !medium.match?(/^Child UUIDs?:/) &&
          medium.scan(/\(UUID: ([0-9a-f-]+)\)/i).flatten == [uuid]
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

        refuse_host_bound_appliance_settings(document)
        files
      end

      def refuse_host_bound_appliance_settings(document)
        machines = REXML::XPath.match(document, "//vbox:Machine", "vbox" => "http://www.virtualbox.org/ovf/machine")
        machines.each do |machine|
          ports = machine.elements.to_a("Hardware/UART/Port")
          if ports.any? { |port| !port.attributes["path"].to_s.empty? || %w{RawFile HostPipe HostDevice TCP}.include?(port.attributes["hostMode"]) }
            raise ActionFailed, "Remove VirtualBox host-connected serial port settings before packaging the VM"
          end

          tpm = machine.elements["Hardware/TrustedPlatformModule"]
          if tpm && (%w{Host Swtpm}.include?(tpm.attributes["type"]) || !tpm.attributes["location"].to_s.empty?)
            raise ActionFailed, "Remove VirtualBox host TPM or external TPM settings before packaging the VM"
          end

          logos = machine.elements.to_a("Hardware/Firmware/Logo | Hardware/BIOS/Logo")
          if logos.any? { |logo| !logo.attributes["imagePath"].to_s.empty? }
            raise ActionFailed, "Remove the VirtualBox custom firmware logo before packaging the VM"
          end
        end
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
