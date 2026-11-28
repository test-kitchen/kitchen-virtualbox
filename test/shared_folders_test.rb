# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

class SharedFoldersTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @registry = File.join(@root, "vm.json")
    @vboxmanage = File.join(@root, "VBoxManage")
    File.write(@vboxmanage, "#!#{RbConfig.ruby}\n" + File.read(File.join(__dir__, "support", "shared_folders_vboxmanage.rb")))
    File.chmod(0o700, @vboxmanage)
    File.write(File.join(@root, "metadata.json"), JSON.generate(provider: "virtualbox"))
    File.write(File.join(@root, "box.ovf"), "")
    assert system("tar", "-cf", File.join(@root, "local.box"), "-C", @root, "metadata.json", "box.ovf")
  end

  def teardown
    FileUtils.remove_entry_secure(@root)
  end

  def test_missing_host_directory_is_rejected_before_import
    configure([["missing", "/mnt/share"]])
    assert_create_rejected(/Synced folder host directory does not exist/)
  end

  def test_rejects_duplicate_normalized_destinations
    FileUtils.mkdir_p(File.join(@root, "share"))
    configure([["share", "/mnt/share"], ["share", "//mnt/./share/"]])
    assert_create_rejected(/guest paths must be unique/)
  end

  def test_rejects_non_boolean_readonly
    configure([[".", "/mnt/share", { "readonly" => "false" }]])
    assert_create_rejected(/options create, disabled and readonly must be boolean/)
  end

  def test_rejects_a_symlink_to_a_managed_host_directory
    managed = File.join(@root, ".kitchen", "managed")
    FileUtils.mkdir_p(managed)
    File.symlink(managed, File.join(@root, "alias"))
    configure([["alias", "/mnt/share"]])
    assert_create_rejected(/must be outside Kitchen's managed/)
  end

  def test_rejects_writable_shares_containing_kitchen_state
    configure([[".", "/mnt/project"]])
    assert_create_rejected(/Writable synced folders must not contain Kitchen's managed/)
  end

  def test_create_retries_share_registration_and_destroy_preserves_host_data
    host = File.join(@root, "host share")
    FileUtils.mkdir_p(host)
    sentinel = File.join(host, "sentinel")
    File.write(sentinel, "host data")
    configure([["host share", "/mnt/read-only", { "readonly" => true }], [host, "/mnt/writable"]])
    File.write(File.join(@root, "fail-start-once"), "")
    output, status = kitchen("create")
    refute status.success?, output
    assert_match(/simulated start failure/, output)

    assert_kitchen("create")
    vm = JSON.parse(File.read(@registry))
    assert_equal "running", vm.fetch("state")
    shares = vm.fetch("shares").map { |_, args| args.reject { |arg| arg.start_with?("--name=") }.sort }
    common = ["--hostpath=#{File.realpath(host)}", "--automount"]
    assert_equal [
      (common + ["--auto-mount-point=/mnt/read-only", "--readonly"]).sort,
      (common + ["--auto-mount-point=/mnt/writable"]).sort,
    ], shares
    assert_kitchen("destroy")
    refute File.exist?(@registry)
    assert_equal "host data", File.read(sentinel)
  end

  def test_default_configuration_registers_no_shares
    configure(nil)
    assert_kitchen("create")
    assert_empty JSON.parse(File.read(@registry)).fetch("shares")
    assert_kitchen("destroy")
  end

  def test_creates_instance_specific_host_directory_and_skips_disabled_share
    configure([
      ["results/%{instance_name}", "/mnt/results", { "create" => true }],
      ["ignored", "/mnt/ignored", { "disabled" => true, "create" => true }],
    ])
    assert_kitchen("create")
    results = File.join(@root, "results", "default-virtualbox")
    assert File.directory?(results)
    refute File.exist?(File.join(@root, "ignored"))
    shares = JSON.parse(File.read(@registry)).fetch("shares").values
    assert_equal 1, shares.size
    assert_includes shares.first, "--hostpath=#{File.realpath(results)}"
    assert_kitchen("destroy")
    assert File.directory?(results)
  end

  private

  def configure(folders)
    driver = {
      "name" => "virtualbox",
      "vboxmanage" => @vboxmanage,
      "box" => File.join(@root, "local.box"),
      "insert_key" => false,
    }
    driver["synced_folders"] = folders unless folders.nil?
    File.write(File.join(@root, "kitchen.yml"), YAML.dump({
      "driver" => driver,
      "transport" => { "name" => "dummy" },
      "provisioner" => { "name" => "dummy" },
      "platforms" => [{ "name" => "virtualbox" }],
      "suites" => [{ "name" => "default" }],
    }))
  end

  def assert_kitchen(action)
    output, status = kitchen(action)
    assert status.success?, output
  end

  def assert_create_rejected(message)
    output, status = kitchen("create")
    refute status.success?, output
    assert_match(message, output)
    refute File.exist?(@registry)
  end

  def kitchen(action)
    output, status = Open3.capture2e({ "VBOX_TEST_REGISTRY" => @registry }, RbConfig.ruby,
      "-I", File.expand_path("../lib", __dir__), Gem.bin_path("test-kitchen", "kitchen"),
      action, "default-virtualbox", chdir: @root)
    log = File.join(@root, ".kitchen", "logs", "default-virtualbox.log")
    output += File.read(log) if !status.success? && File.file?(log)
    [output, status]
  end
end
