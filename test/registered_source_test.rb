# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"

class RegisteredSourceTest < Minitest::Test
  SOURCE = "11111111-1111-4111-8111-111111111111".freeze

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

  def test_full_clone_applies_network_and_hardware_overrides_and_reuses_them
    source = registry.fetch(SOURCE).merge("nic2" => "nat", "nic3" => "bridged",
      "forwarding1" => "inherited-ssh", "forwarding2" => "inherited-web", "cpus" => "1", "memory" => "1024")
    File.write(@registry, JSON.generate(SOURCE => source))

    configure_clone_network
    assert_match(%r{ip -4 address replace 192[.]0[.]2[.]31/24}, assert_kitchen("create"))
    assert_kitchen "create"
    assert_clone_network

    assert_kitchen "destroy"
    assert_equal({ SOURCE => source }, registry)
  end

  def test_running_source_is_rejected_before_cloning
    source_state("running")
    output, status = kitchen("create")
    refute status.success?, output
    assert_match(/must be powered off.*running/i, output)
    assert_kitchen "destroy"
    assert_equal({ SOURCE => { "name" => "Disposable source", "state" => "running" } }, registry)
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

  def configure_clone_network
    @forward_port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
    settings = <<~YAML
      insert_key: false
      cpus: 2
      memory: 2048
      port_forward:
        host_port: #{@forward_port}
        guest_port: 8080
      private_network: clone-test
      private_address: 192.0.2.31/24
    YAML
    File.write(@configuration, File.read(@configuration).sub("  insert_key: false\n", settings.lines.map { |line| "  #{line}" }.join))
  end

  def assert_clone_network
    clone = registry.find { |id, _| id != SOURCE }.last
    assert_equal %w{intnet clone-test none 2 2048}, clone.values_at("nic2", "intnet2", "nic3", "cpus", "memory")
    refute clone.key?("forwarding1")
    forwards = clone.fetch("forwards")
    assert_equal 2, forwards.length
    ssh, forward = forwards
    assert_match(/\Akitchen-ssh,tcp,127[.]0[.]0[.]1,\d+,,22\z/, ssh)
    assert_equal "kitchen-forward,tcp,127.0.0.1,#{@forward_port},,8080", forward
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
    output
  end
end
