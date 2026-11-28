# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

describe "VirtualBox diagnostics through Kitchen" do
  let(:uuid) { "12345678-1234-1234-1234-123456789abc" }

  provider_script = <<~'RUBY'
    case ARGV
    when %w{list vms}
      abort "VirtualBox host unavailable" if ENV["VBOX_SCENARIO"] == "unavailable"
      puts %("disposable-vm" {#{ENV.fetch("VBOX_FIXTURE_UUID")}}) if ENV["VBOX_SCENARIO"] == "running"
    when ["showvminfo", ENV.fetch("VBOX_FIXTURE_UUID"), "--machinereadable"]
      abort "VM is missing" unless ENV["VBOX_SCENARIO"] == "running"
      puts 'VMState="running"'
    else
      File.write("unexpected-provider-command", ARGV.inspect)
      abort "Unexpected provider command"
    end
  RUBY

  before do
    @directory = Dir.mktmpdir
    provider = File.join(@directory, "VBoxManage")
    File.write(provider, "#!#{RbConfig.ruby}\n#{provider_script}")
    File.chmod(0o755, provider)
    File.write(File.join(@directory, "kitchen.yml"), <<~YAML)
      driver:
        name: virtualbox
        vboxmanage: #{provider}
        box: demo.box
      provisioner:
        name: shell
      platforms:
        - name: virtualbox
      suites:
        - name: default
    YAML
    File.write(File.join(@directory, "demo.box"), "")
    Dir.mkdir(File.join(@directory, ".kitchen"))
    @state = File.join(@directory, ".kitchen", "default-virtualbox.yml")
    @saved_state = "virtualbox_uuid: #{uuid}\n"
    File.write(@state, @saved_state)
  end

  after do
    FileUtils.remove_entry(@directory)
  end

  it "reports a running VM and passes host diagnostics without changing state" do
    status = live_status("running")
    _(status.values_at("live", "state", "resource_id")).must_equal [true, "running", uuid]

    output, process = kitchen("running", "doctor")
    _(process.success?).must_equal true, output
  end

  it "reports a missing VM and diagnoses a missing box" do
    status = live_status("missing")
    _(status.values_at("live", "state")).must_equal [false, "not_created"]

    File.delete(File.join(@directory, "demo.box"))
    output, process = kitchen("missing", "doctor")
    _(process.exitstatus).must_equal 1
    _(output).must_match(/readable local \.box archive: .*demo\.box/)
  end

  it "reports an unavailable provider and retains the saved VM ID" do
    status = live_status("unavailable")
    _(status.values_at("live", "state", "resource_id")).must_equal [nil, "unknown", uuid]
    _(status.fetch("message")).must_include "VirtualBox host unavailable"

    output, process = kitchen("unavailable", "doctor")
    _(process.exitstatus).must_equal 1
    _(output).must_include "VirtualBox host unavailable"
  end

  it "checks catalog boxes without creating a cache or a lease" do
    config = File.join(@directory, "kitchen.yml")
    settings = YAML.safe_load_file(config)
    settings.fetch("driver").merge!(
      "box_manifest" => "manifest.json",
      "box_cache" => File.join(@directory, "box-cache"),
      "box" => { "name" => "demo", "version" => "1.0.0" }
    )
    File.write(config, YAML.dump(settings))
    box = File.join(@directory, "demo.box")
    File.write(box, "box archive fixture")
    architecture = RbConfig::CONFIG.fetch("host_cpu")
    architecture = { "aarch64" => "arm64", "x86_64" => "amd64" }.fetch(architecture, architecture)
    entry = { name: "demo", version: "1.0.0", provider: "virtualbox", architecture: architecture,
              file: "demo.box", bytes: File.size(box), sha256: Digest::SHA256.file(box).hexdigest }
    File.write(File.join(@directory, "manifest.json"), JSON.generate([entry]))

    output, process = kitchen("missing", "doctor")
    _(process.success?).must_equal true, output

    File.delete(box)
    output, process = kitchen("missing", "doctor")
    _(process.exitstatus).must_equal 1
    _(output).must_include "Cannot read box demo.box"
    _(File.exist?(File.join(@directory, "box-cache"))).must_equal false
  end

  def live_status(scenario)
    output, process = kitchen(scenario, "list", "--live", "--json")
    _(process.success?).must_equal true, output
    JSON.parse(output).fetch(0).fetch("status")
  end

  def kitchen(scenario, *arguments)
    env = { "VBOX_SCENARIO" => scenario, "VBOX_FIXTURE_UUID" => uuid }
    lib = File.expand_path("../lib", __dir__)
    executable = Gem.bin_path("test-kitchen", "kitchen")
    output, process = Open3.capture2e(env, RbConfig.ruby, "-I", lib, executable, *arguments, chdir: @directory)
    _(File.exist?(File.join(@directory, "unexpected-provider-command"))).must_equal false, output
    _(File.read(@state)).must_equal @saved_state
    [output, process]
  end
end
