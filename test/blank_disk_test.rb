# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

class BlankDiskTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @registry = File.join(@root, "vm.json")
    @external_disk = File.join(@root, "external.vdi")
    File.write(@external_disk, "unrelated disk")
    @vboxmanage = File.join(@root, "VBoxManage")
    File.write(@vboxmanage, "#!#{RbConfig.ruby}\n" + File.read(File.join(__dir__, "support", "blank_disk_vboxmanage.rb")))
    File.chmod(0o700, @vboxmanage)
    File.write(File.join(@root, "box.ovf"), "")
    File.write(File.join(@root, "metadata.json"), '{"provider":"virtualbox"}')
    Dir.chdir(@root) { system("tar", "-cf", "local.box", "metadata.json", "box.ovf", exception: true) }
  end

  def teardown
    FileUtils.remove_entry_secure(@root)
  end

  def test_create_and_destroy_a_blank_disk_and_preserve_external_media
    configure(512)
    assert_kitchen "create"
    boot_disk = registry.fetch("disks").fetch("Storage-0-0")
    disk = registry.fetch("disks").fetch("Storage-2-0")
    assert_equal "512", File.read(disk)
    assert_kitchen "create"
    assert_equal disk, registry.fetch("disks").fetch("Storage-2-0")

    assert_kitchen "destroy"
    refute File.exist?(boot_disk)
    refute File.exist?(disk)
    refute File.exist?(@registry)
    assert_equal "unrelated disk", File.read(@external_disk)
  end

  def test_retry_after_attachment_fails_reuses_the_created_disk
    configure(512)
    File.write(File.join(@root, "fail-attach-once"), "")
    output, status = kitchen("create")
    refute status.success?, output
    assert_match(/simulated attach failure/, output)
    assert_kitchen "create"
    assert_equal "512", File.read(registry.fetch("disks").fetch("Storage-2-0"))
    assert_kitchen "destroy"
  end

  def test_destroy_preserves_an_unrelated_disk_inside_the_instance_directory
    configure(512)
    assert_kitchen "create"
    vm = registry
    owned_disk = vm.fetch("disks").fetch("Storage-2-0")
    unrelated_disk = File.join(File.dirname(owned_disk), "test-disk.vdi")
    File.write(unrelated_disk, "unrelated disk inside the instance directory")
    vm.fetch("disks")["Storage-1-0"] = unrelated_disk
    File.write(@registry, JSON.generate(vm))

    assert_kitchen "destroy"
    refute File.exist?(owned_disk)
    assert_equal "unrelated disk inside the instance directory", File.read(unrelated_disk)
  end

  def test_destroy_after_attachment_fails_removes_the_unattached_disk
    configure(512)
    File.write(File.join(@root, "fail-attach-once"), "")
    output, status = kitchen("create")
    refute status.success?, output
    assert_match(/simulated attach failure/, output)
    disk = JSON.parse(File.read(File.join(@root, "media.json"))).values.find { |path| path.include?("test-disk-") }
    assert File.file?(disk)
    assert_kitchen "destroy"
    refute File.exist?(disk)
    assert_equal "unrelated disk", File.read(@external_disk)
  end

  def test_destroy_preserves_replacement_file_at_an_owned_disk_path
    configure(512)
    assert_kitchen "create"
    disk = registry.fetch("disks").fetch("Storage-2-0")
    replacement = "#{disk}.replacement"
    File.write(replacement, "replacement disk")
    File.rename(replacement, disk)

    assert_kitchen "destroy"
    assert_equal "replacement disk", File.read(disk)
  end

  def test_destroy_refuses_to_delete_a_vm_with_snapshot_only_media
    configure(512)
    assert_kitchen "create"
    vm = registry
    vm["snapshot_disks"] = [vm.fetch("disks").delete("Storage-1-0")]
    File.write(@registry, JSON.generate(vm))

    output, status = kitchen("destroy")
    refute status.success?, output
    assert_match(/snapshot media ownership is unverified/, output)
    assert_equal vm, registry
    assert_equal "unrelated disk", File.read(@external_disk)
  end

  def test_destroy_preserves_replacement_medium_with_a_different_uuid
    configure(512)
    assert_kitchen "create"
    disk = registry.fetch("disks").fetch("Storage-2-0")
    registry_path = File.join(@root, "media.json")
    media = JSON.parse(File.read(registry_path))
    media.delete(media.key(disk))
    media["22222222-2222-4222-8222-222222222222"] = disk
    File.write(registry_path, JSON.generate(media))

    assert_kitchen "destroy"
    assert_equal "512", File.read(disk)
  end

  def test_create_after_vm_disappears_uses_a_new_blank_disk
    configure(512)
    assert_kitchen "create"
    old_vm = registry
    old_disk = old_vm.fetch("disks").fetch("Storage-2-0")
    File.write(old_disk, "old guest data")
    File.delete(@registry)

    assert_kitchen "create"
    new_vm = registry
    new_disk = new_vm.fetch("disks").fetch("Storage-2-0")
    refute_equal old_vm.fetch("uuid"), new_vm.fetch("uuid")
    refute_equal old_disk, new_disk
    assert_equal "512", File.read(new_disk)
    assert_kitchen "destroy"
    assert_equal "old guest data", File.read(old_disk)
  end

  def test_omitting_the_option_preserves_the_default_disk_layout
    configure
    assert_kitchen "create"
    assert_equal %w{Storage-0-0 Storage-1-0}, registry.fetch("disks").keys
    assert_kitchen "destroy"
  end

  def test_invalid_disk_size_fails_before_creating_a_vm
    configure(0)
    output, status = kitchen("create")
    refute status.success?, output
    assert_match(/disk_size_mib must be a positive integer/, output)
    refute File.exist?(@registry)
  end

  private

  def configure(size = nil)
    config = {
      "driver" => { "name" => "virtualbox", "box" => "local.box", "vboxmanage" => @vboxmanage, "insert_key" => false },
      "transport" => { "name" => "dummy" },
      "provisioner" => { "name" => "dummy" },
      "platforms" => [{ "name" => "virtualbox" }],
      "suites" => [{ "name" => "default" }],
    }
    config["driver"]["disk_size_mib"] = size unless size.nil?
    File.write(File.join(@root, "kitchen.yml"), YAML.dump(config))
  end

  def registry
    JSON.parse(File.read(@registry))
  end

  def kitchen(action)
    output, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__),
      Gem.bin_path("test-kitchen", "kitchen"), action, "default-virtualbox", chdir: @root)
    log = File.join(@root, ".kitchen", "logs", "default-virtualbox.log")
    output += File.read(log) if !status.success? && File.file?(log)
    [output, status]
  end

  def assert_kitchen(action)
    output, status = kitchen(action)
    assert status.success?, output
  end
end
