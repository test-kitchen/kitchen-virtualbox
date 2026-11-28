# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "kitchen/driver/virtualbox"

class PackageTest < Minitest::Test
  TOKEN = "61c7f507-dfd3-4576-a70a-864ac23de492".freeze
  Instance = Struct.new(:name, :logger, :transport)

  def setup
    @root = Dir.mktmpdir
    @vm_dir = File.join(@root, ".kitchen", "virtualbox-#{TOKEN}")
    FileUtils.mkdir_p(@vm_dir)
    @driver = Kitchen::Driver::Virtualbox.new(kitchen_root: @root, vboxmanage: "/usr/bin/false")
    @driver.finalize_config!(Instance.new("source", Logger.new(File::NULL), {}))
    @state = { virtualbox_token: TOKEN, virtualbox_uuid: TOKEN, virtualbox_name: "source" }
    @history = File.join(@vm_dir, "no-kitchen-key")
    File.write(@history, TOKEN)
    Kitchen::StateFile.new(@root, "source").write(@state)
    @output = File.join(@root, "source.box")
  end

  def teardown
    FileUtils.remove_entry_secure(@root)
  end

  def test_refuses_an_instance_with_a_recorded_kitchen_key
    %i{virtualbox_generated_key virtualbox_key_injected}.each do |flag|
      assert_refused(@state.merge(flag => true), /Cannot safely remove the Kitchen-injected SSH key/)
    end
    refute_path_exists(@output)
  end

  def test_refuses_a_legacy_instance_with_a_local_kitchen_key
    File.write(File.join(@vm_dir, "ssh_key"), "")
    assert_refused(@state, /Cannot safely remove the Kitchen-injected SSH key/)
    refute_path_exists(@output)
  end

  def test_refuses_missing_or_mismatched_key_history
    File.delete(@history)
    assert_refused(@state, /Cannot safely remove the Kitchen-injected SSH key/)
    File.write(@history, SecureRandom.uuid)
    assert_refused(@state, /Cannot safely remove the Kitchen-injected SSH key/)
  end

  def test_failed_key_injection_invalidates_history_before_touching_the_guest
    history = @history
    @driver.define_singleton_method(:install_guest_key) do |*|
      raise "History still present" if File.exist?(history)

      raise Kitchen::ActionFailed, "Guest control failed"
    end

    error = assert_raises(Kitchen::ActionFailed) { @driver.send(:configure_ssh, TOKEN, @state) }
    assert_equal("Guest control failed", error.message)
    refute_path_exists(@history)
    assert_refused(@state.reject { |key, _| key == :virtualbox_key_injected }, /Cannot safely remove the Kitchen-injected SSH key/)
  end

  def test_refuses_vmdk_before_export
    mock_export(disk_name: "source.vmdk")
    assert_refused(@state, /requires standalone VDI disks/)
  end

  def test_refuses_a_disk_attached_to_another_vm_before_export
    mock_export(extra_medium_info: "             other (UUID: #{SecureRandom.uuid})\n")
    assert_refused(@state, /requires standalone VDI disks/)
  end

  def test_publishes_a_complete_box_and_preserves_it_on_retry
    mock_export { |appliance| write_appliance(appliance) }

    assert_equal(@output, @driver.package(@state))
    assert_equal(%w{box.ovf disk.vmdk metadata.json}, IO.popen(["/usr/bin/tar", "-tf", @output], &:read).lines.map(&:chomp).sort)
    assert_equal(0o600, File.stat(@output).mode & 0o777)
    original = File.binread(@output)
    assert_refused(@state, /Package already exists/)
    assert_equal(original, File.binread(@output))
  end

  def test_preserves_a_box_published_during_export
    mock_export do |appliance|
      write_appliance(appliance)
      File.write(@output, "concurrent box")
    end

    assert_refused(@state, /Package already exists/)
    assert_equal("concurrent box", File.read(@output))
    assert_empty(Dir.glob(File.join(@root, ".virtualbox-package-*")))
  end

  def test_preserves_existing_output
    File.write(@output, "existing box")
    assert_refused(@state, /Package already exists/)
    assert_equal("existing box", File.read(@output))
  end

  def test_refuses_an_export_with_a_missing_disk
    mock_export do |appliance|
      File.write(appliance, <<~XML)
        <Envelope xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/2">
          <References><File ovf:href="disk.vmdk"/></References>
        </Envelope>
      XML
    end

    assert_refused(@state, /VirtualBox export is missing disk or firmware data/)
    refute_path_exists(@output)
    assert_empty(Dir.glob(File.join(@root, ".virtualbox-package-*")))
  end

  def test_refuses_host_bound_settings_in_the_export
    hardware = nil
    mock_export { |appliance| write_appliance(appliance, hardware: hardware) }
    {
      "serial port" => '<UART><Port enabled="false" hostMode="RawFile" path="/tmp/serial.log"/></UART>',
      "external TPM" => '<TrustedPlatformModule type="Swtpm" location="/tmp/tpm.sock"/>',
      "host TPM" => '<TrustedPlatformModule type="Host" location=""/>',
      "firmware logo" => '<Firmware><Logo imagePath="/tmp/logo.bmp"/></Firmware>',
    }.each do |setting, configuration|
      hardware = configuration
      assert_refused(@state, /Remove .*#{setting}.* before packaging/)
      refute_path_exists(@output)
      assert_empty(Dir.glob(File.join(@root, ".virtualbox-package-*")))
    end
  end

  def test_accepts_portable_hardware_in_the_export
    hardware = <<~XML
      <TrustedPlatformModule type="v2_0" location=""/>
      <UART><Port enabled="true" hostMode="Disconnected"/></UART>
      <Firmware><Logo fadeIn="false"/></Firmware>
    XML
    mock_export { |appliance| write_appliance(appliance, hardware: hardware) }

    assert_equal(@output, @driver.package(@state))
  end

  private

  def write_appliance(appliance, hardware: "")
    File.write(File.join(File.dirname(appliance), "disk.vmdk"), "exported disk")
    File.write(appliance, <<~XML)
      <Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/2"
                xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/2"
                xmlns:vbox="http://www.virtualbox.org/ovf/machine">
        <References><File ovf:href="disk.vmdk" ovf:size="13"/></References>
        <VirtualSystem><vbox:Machine><Hardware>#{hardware}</Hardware></vbox:Machine></VirtualSystem>
      </Envelope>
    XML
  end

  def mock_export(disk_name: "source.vdi", extra_medium_info: "", &export)
    disk = File.join(@vm_dir, disk_name)
    File.write(disk, "source disk")
    @driver.define_singleton_method(:vbox) do |*args|
      case args.first
      when "list"
        %("source" {#{PackageTest::TOKEN}}\n)
      when "showvminfo"
        <<~INFO
          name="source"
          VMState="poweroff"
          storagecontrollername0="SATA"
          "SATA-0-0"="#{disk}"
          "SATA-ImageUUID-0-0"="#{PackageTest::TOKEN}"
        INFO
      when "showmediuminfo"
        <<~INFO + extra_medium_info
          Parent UUID:    base
          Type:           normal (base)
          Storage format: vdi
          In use by VMs:  source (UUID: #{PackageTest::TOKEN})
        INFO
      when "export"
        export.call(args.fetch(3))
      when "import"
        raise "Expected a dry run" unless args.last == "--dry-run"
      else
        raise "Unexpected VBoxManage command: #{args.inspect}"
      end
    end
  end

  def assert_refused(state, message)
    error = assert_raises(Kitchen::ActionFailed) { @driver.package(state) }
    assert_match(message, error.message)
  end
end
