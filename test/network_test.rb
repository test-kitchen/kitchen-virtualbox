# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "open3"
require "tmpdir"
require "yaml"

Dir.mktmpdir("kitchen-virtualbox-network") do |root|
  name = "network-virtualbox"
  uuid = "9135d992-4a17-4748-99cd-b51c04080b28"
  vbox = File.join(root, "VBoxManage")
  File.write(vbox, <<~RUBY)
    #!#{RbConfig.ruby}
    case ARGV.first
    when "list"
      puts '"disposable" {#{uuid}}' unless File.exist?("removed")
    when "showvminfo"
      puts File.exist?("stopped") ? 'VMState="poweroff"' : 'VMState="running"'
      puts 'nic2="intnet"'
      puts 'intnet2="kitchen-test"'
      puts 'macaddress2="080027A1B2C3"'
      puts 'Forwarding(0)="kitchen-ssh,tcp,127.0.0.1,56700,,22"'
      puts 'Forwarding(1)="kitchen-forward,tcp,127.0.0.1,56701,,8080"'
    when "controlvm", "unregistervm"
      File.write("removed", "") if ARGV == ["unregistervm", "#{uuid}", "--delete"]
    else
      abort "Unexpected VBoxManage call"
    end
  RUBY
  File.chmod(0o700, vbox)
  config = File.join(root, "kitchen.yml")
  File.write(config, <<~YAML)
    driver:
      name: virtualbox
      vboxmanage: #{vbox}
      insert_key: false
      port_forward: { host_port: 56701, guest_port: 8080 }
      private_network: kitchen-test
      private_address: 192.0.2.31/24
    transport:
      name: dummy
      sleep: 0
    provisioner:
      name: dummy
    platforms:
      - name: virtualbox
    suites:
      - name: network
  YAML
  Dir.mkdir(File.join(root, ".kitchen"))
  state = File.join(root, ".kitchen", "#{name}.yml")
  File.write(state, YAML.dump("virtualbox_token" => uuid, "virtualbox_uuid" => uuid))
  kitchen = [RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), Gem.bin_path("test-kitchen", "kitchen")]
  invoke = lambda do |action|
    output, result = Open3.capture2e(*kitchen, action, name, chdir: root)
    log = File.join(root, ".kitchen", "logs", "#{name}.log")
    output += File.read(log) if !result.success? && File.file?(log)
    [output, result]
  end
  output, result = invoke.call("create")
  abort output unless result.success? && output.include?("ip -4 address replace 192.0.2.31/24")
  abort "SSH endpoint changed" unless YAML.safe_load_file(state).values_at("hostname", "port") == ["127.0.0.1", 56700]

  original_config = File.read(config)
  File.write(config, original_config.sub("56701", "56702"))
  output, result = invoke.call("create")
  abort output unless !result.success? && output.include?("different networking settings")
  abort "Settings changed on a running VM" unless YAML.safe_load_file(state)["port"] == 56700

  File.write(config, original_config.sub("192.0.2.31/24", "192.0.2.999/24"))
  output, result = invoke.call("create")
  abort output unless !result.success? && output.include?("requires a valid IPv4 CIDR address")

  stopped = File.join(root, "stopped")
  File.write(stopped, "")
  File.write(config, original_config.lines.reject { |line| line.start_with?("  private_") }.join)
  output, result = invoke.call("create")
  abort output unless !result.success? && output.include?("different private networking settings")
  abort "Private attachment intent was lost" unless YAML.safe_load_file(state)["virtualbox_private_network"] == "kitchen-test"
  File.delete(stopped)

  output, result = invoke.call("destroy")
  abort output unless result.success? && File.exist?(File.join(root, "removed")) && !File.exist?(state)
end
