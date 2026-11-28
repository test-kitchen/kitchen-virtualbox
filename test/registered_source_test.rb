# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class RegisteredSourceTest < Minitest::Test
  SOURCE = "11111111-1111-4111-8111-111111111111".freeze
  FOREIGN = "22222222-2222-4222-8222-222222222222".freeze

  def setup
    @root = Dir.mktmpdir
    @registry = File.join(@root, "registry.json")
    @vboxmanage = File.join(@root, "VBoxManage")
    File.write(@vboxmanage, "#!#{RbConfig.ruby}\n" + File.read(File.join(__dir__, "support", "vboxmanage.rb")))
    File.chmod(0o700, @vboxmanage)
    @configuration = File.join(@root, "kitchen.yml")
    File.write(@configuration, <<~YAML)
      driver:
        name: virtualbox
        vboxmanage: #{@vboxmanage}
        source_vm: Disposable source
        insert_key: false
      transport:
        name: dummy
      provisioner:
        name: dummy
      platforms:
        - name: virtualbox
      suites:
        - name: default
    YAML
    source_state("poweroff")
  end

  def teardown
    FileUtils.remove_entry_secure(@root)
  end

  def test_create_runs_a_full_clone_and_destroy_preserves_the_source
    source = registry.fetch(SOURCE)
    source.merge!("nic2" => "nat", "share" => "inherited-share", "forwarding1" => "web", "forwarding2" => "other-web", "cable1" => "off")
    File.write(@registry, JSON.generate(SOURCE => source))

    assert_kitchen "create"
    assert_equal 2, registry.size
    uuid, vm = registry.find { |id, _| id != SOURCE }
    assert_equal "running", vm.fetch("state")
    assert_equal SOURCE, vm.fetch("source")
    assert_equal "none", vm.fetch("nic2")
    refute vm.key?("share")
    refute vm.key?("forwarding1")
    assert File.directory?(File.join(@root, ".kitchen", "virtualbox-#{uuid}"))
    assert_kitchen "destroy"
    assert_equal({ SOURCE => source }, registry)
    refute File.exist?(File.join(@root, ".kitchen", "virtualbox-#{uuid}"))
  end

  def test_running_source_is_rejected_before_cloning
    source_state("running")
    output, status = kitchen("create")
    refute status.success?, output
    assert_match(/must be powered off.*running/i, output)
    assert_kitchen "destroy"
    assert_equal({ SOURCE => { "name" => "Disposable source", "state" => "running" } }, registry)
  end

  def test_converge_and_destroy_a_linked_clone_without_deleting_shared_media
    source = configure_linked_clone
    root_alias = File.join(@root, "alias")
    File.symlink(@root, root_alias)
    File.open(@configuration, "a") { |file| file.puts "kitchen:\n  kitchen_root: #{root_alias}" }
    assert_kitchen "converge"
    uuid, clone = registry.find { |id, _| id != SOURCE }
    assert_equal "clean template", clone.fetch("linked_snapshot")
    assert_equal "running", clone.fetch("state")
    disks = File.join(@root, "disks.json")
    inventory = JSON.parse(File.read(disks))
    assert_equal [SOURCE, uuid], inventory.keys
    disk_path, parent = inventory.fetch(uuid)
    aliased_path = File.join(root_alias, disk_path.delete_prefix("#{File.realpath(@root)}/"))
    File.write(disks, JSON.generate(inventory.merge(uuid => [aliased_path, parent])))
    File.write(File.join(@root, "fail_unregister_once"), "")
    output, status = kitchen("destroy")
    refute status.success?, output
    assert_match(/simulated unregister failure/, output)
    assert_equal({ SOURCE => source }, registry)
    assert_equal [SOURCE, uuid], JSON.parse(File.read(disks)).keys
    assert File.directory?(File.join(@root, ".kitchen", "virtualbox-#{uuid}"))

    File.write(File.join(@root, "fail_close_once"), "")
    output, status = kitchen("destroy")
    refute status.success?, output
    assert_match(/simulated disk close failure/, output)
    assert_kitchen "destroy"
    assert_equal({ SOURCE => source }, registry)
    assert_equal [SOURCE], JSON.parse(File.read(disks)).keys
    refute File.exist?(File.join(@root, ".kitchen", "virtualbox-#{uuid}"))
  end

  def test_destroy_preserves_an_unrelated_disk_inside_the_instance_directory
    configure_linked_clone
    assert_kitchen "create"
    uuid, = registry.find { |id, _| id != SOURCE }
    directory = File.join(@root, ".kitchen", "virtualbox-#{uuid}")
    unrelated = File.join(directory, "unrelated.vdi")
    File.write(unrelated, "unrelated")
    unregistered = File.join(directory, "offline.vmdk")
    File.write(unregistered, "offline")
    disks = File.join(@root, "disks.json")
    inventory = JSON.parse(File.read(disks))
    inventory[FOREIGN] = [unrelated, "base"]
    File.write(disks, JSON.generate(inventory))
    File.write(File.join(@root, "close_on_unregister"), "")

    assert_kitchen "destroy"
    assert_equal "unrelated", File.read(unrelated)
    assert_equal "offline", File.read(unregistered)
    assert_equal inventory.except(uuid), JSON.parse(File.read(disks))
    refute File.exist?(inventory.fetch(uuid).first)
  end

  def test_destroy_refuses_to_delete_a_disk_if_its_parent_chain_changed
    configure_linked_clone
    assert_kitchen "create"
    uuid, = registry.find { |id, _| id != SOURCE }
    disks = File.join(@root, "disks.json")
    inventory = JSON.parse(File.read(disks))
    changed = inventory.merge(uuid => [inventory.fetch(uuid).first, "base"])
    File.write(disks, JSON.generate(changed))

    output, status = kitchen("destroy")
    refute status.success?, output
    assert_match(/parent chain changed/, output)
    assert File.exist?(inventory.fetch(uuid).first)
    File.write(disks, JSON.generate(inventory))
    assert_kitchen "destroy"
  end

  def test_retry_requires_the_original_source_and_snapshot_until_destroy
    configure_linked_clone
    original = File.read(@configuration)
    File.write(File.join(@root, "fail_clone_once"), "")
    output, status = kitchen("create")
    refute status.success?, output
    assert_match(/simulated clone failure/, output)

    [original.sub("Disposable source", SOURCE), original.sub(/^  source_snapshot:.*\n/, "")].each do |configuration|
      File.write(@configuration, configuration)
      output, status = kitchen("create")
      refute status.success?, output
      assert_match(/Run kitchen destroy/, output)
    end
    assert_kitchen "destroy"
    assert_equal [SOURCE], registry.keys
  end

  def test_snapshot_requires_a_registered_source
    File.write(@configuration, File.read(@configuration).sub(
      "source_vm: Disposable source", "source_snapshot: clean template"
    ))
    before = registry

    output, status = kitchen("create")
    refute status.success?, output
    assert_match(/source_snapshot.*with driver.source_vm and without driver.box/, output)
    assert_equal before, registry
  end

  def test_retry_recovers_a_clone_registered_before_the_command_failed
    File.write(@configuration, File.read(@configuration).sub("source_vm: Disposable source", "source_vm: #{SOURCE}"))
    File.write(File.join(@root, "fail_clone_once"), "")
    output, status = kitchen("create")
    refute status.success?, output
    assert_match(/simulated clone failure/, output)
    uuid, vm = registry.find { |id, _| id != SOURCE }
    assert_equal "poweroff", vm.fetch("state")
    assert_kitchen "create"
    assert_equal [SOURCE, uuid], registry.keys
    assert_equal "running", registry.fetch(uuid).fetch("state")
    assert_kitchen "destroy"
    assert_equal [SOURCE], registry.keys
  end

  private

  def configure_linked_clone
    File.write(@configuration, File.read(@configuration).sub(
      "source_vm: Disposable source", "source_vm: Disposable source\n  source_snapshot: clean template"
    ))
    source = registry.fetch(SOURCE).merge("snapshot" => "clean template")
    File.write(@registry, JSON.generate(SOURCE => source))
    source_disk = File.join(@root, "source.vmdk")
    File.write(source_disk, "")
    File.write(File.join(@root, "disks.json"), JSON.generate(SOURCE => [source_disk, "base"]))
    source
  end

  def source_state(state)
    File.write(@registry, JSON.generate(SOURCE => { "name" => "Disposable source", "state" => state }))
  end

  def registry
    JSON.parse(File.read(@registry))
  end

  def kitchen(action)
    output, status = Open3.capture2e({ "VBOX_TEST_REGISTRY" => @registry }, RbConfig.ruby,
      "-I", File.expand_path("../lib", __dir__), Gem.bin_path("test-kitchen", "kitchen"),
      action, "default-virtualbox", chdir: @root)
    log = File.join(@root, ".kitchen", "logs", "default-virtualbox.log")
    output += File.read(log) if !status.success? && File.file?(log)
    [output, status]
  end

  def assert_kitchen(action)
    output, status = kitchen(action)
    assert status.success?, output
  end
end
