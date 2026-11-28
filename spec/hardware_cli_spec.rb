# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

class HardwareCliSpec < Minitest::Test
  def test_sets_configured_hardware_on_import
    assert_hardware_options({ "cpus" => 2, "memory" => 3072 }, %w{--cpus 2 --memory 3072})
  end

  def test_preserves_image_hardware_defaults
    assert_hardware_options({}, [])
  end

  def test_preserves_image_default_for_an_omitted_setting
    assert_hardware_options({ "cpus" => 2 }, %w{--cpus 2})
    assert_hardware_options({ "memory" => 3072 }, %w{--memory 3072})
  end

  def test_rejects_invalid_hardware_before_calling_virtualbox
    %w{cpus memory}.product([0, -1, 1.5, "2", false]).each do |setting, value|
      create_vm(setting => value) do |output, status, calls|
        refute status.success?
        assert_includes output, "driver.#{setting} must be a positive integer"
        assert_empty calls
      end
    end
  end

  def test_rejects_hardware_outside_virtualbox_limits_before_calling_virtualbox
    { "cpus" => [65], "memory" => [3, 2_097_153] }.each do |setting, values|
      values.each do |value|
        create_vm(setting => value) do |output, status, calls|
          refute status.success?
          assert_includes output, "driver.#{setting} must be within VirtualBox's supported range"
          assert_empty calls
        end
      end
    end
  end

  private

  def assert_hardware_options(settings, expected)
    create_vm(settings) do |output, status, calls|
      assert status.success?, output
      import = calls.find { |arguments| arguments.first == "import" }
      refute_nil import
      options = import.drop(2).each_slice(2).to_h
      assert_equal expected, options.slice("--cpus", "--memory").to_a.flatten
      assert(calls.any? { |arguments| arguments.first == "startvm" })
    end
  end

  def create_vm(settings)
    Dir.mktmpdir do |root|
      File.write(File.join(root, "box.ovf"), "")
      File.write(File.join(root, "metadata.json"), JSON.generate(provider: "virtualbox"))
      assert system("tar", "-cf", "local.box", "box.ovf", "metadata.json", chdir: root)
      File.write(File.join(root, "kitchen.yml"), YAML.dump(
        "driver" => { "name" => "virtualbox", "box" => "local.box", "vboxmanage" => "./fake-vboxmanage",
                      "insert_key" => false }.merge(settings),
        "transport" => { "name" => "dummy" },
        "provisioner" => { "name" => "shell" },
        "platforms" => [{ "name" => "linux" }],
        "suites" => [{ "name" => "default" }]
      ))
      fake_vboxmanage = File.join(root, "fake-vboxmanage")
      File.write(fake_vboxmanage, <<~RUBY)
        #!#{RbConfig.ruby}
        require "json"
        File.open("calls.jsonl", "a") { |file| file.puts(JSON.generate(ARGV)) }
        case ARGV.first
        when "import"
          File.write("registered", ARGV.fetch(ARGV.index("--vmname") + 1))
        when "list"
          puts %Q{"\#{File.read("registered")}" {aabb-1234}} if File.exist?("registered")
        when "showvminfo"
          puts 'VMState="poweroff"'
        end
      RUBY
      File.chmod(0o755, fake_vboxmanage)
      lib = File.expand_path("../lib", __dir__)
      output, status = Open3.capture2e(RbConfig.ruby, "-I", lib, Gem.bin_path("test-kitchen", "kitchen"),
        "create", "--log-level", "debug", chdir: root)
      calls_path = File.join(root, "calls.jsonl")
      calls = File.exist?(calls_path) ? File.readlines(calls_path).map { |line| JSON.parse(line) } : []
      yield output, status, calls
    end
  end
end
