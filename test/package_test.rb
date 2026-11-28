# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "kitchen/driver/virtualbox"

class PackageTest < Minitest::Test
  TOKEN = "61c7f507-dfd3-4576-a70a-864ac23de492".freeze
  Instance = Struct.new(:name, :logger)

  def setup
    @root = Dir.mktmpdir
    @vm_dir = File.join(@root, ".kitchen", "virtualbox-#{TOKEN}")
    FileUtils.mkdir_p(@vm_dir)
    @driver = Kitchen::Driver::Virtualbox.new(kitchen_root: @root, vboxmanage: "/usr/bin/false")
    @driver.finalize_config!(Instance.new("source", Logger.new(File::NULL)))
    @state = { virtualbox_token: TOKEN, virtualbox_uuid: TOKEN, virtualbox_name: "source" }
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

  private

  def mock_export(&export)
    disk = File.join(@vm_dir, "source.vmdk")
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
        "Parent UUID:    base\n"
      when "export"
        export.call(args.fetch(3))
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
