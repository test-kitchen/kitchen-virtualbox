# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "open3"
require "socket"
require "tmpdir"
require "yaml"

Dir.mktmpdir("kitchen-virtualbox-network") do |root|
  name = "network-virtualbox"
  vbox = File.join(root, "VBoxManage")
  File.write(vbox, "#!#{RbConfig.ruby}\n" + <<~'RUBY')
    require "yaml"

    command, _target, *options = ARGV
    vm = YAML.safe_load_file("vm.yml") if File.exist?("vm.yml")
    case command
    when "list"
      puts %("#{vm.fetch("name")}" {9135d992-4a17-4748-99cd-b51c04080b28}) if vm
    when "import"
      name = options.fetch(options.index("--vmname") + 1)
      vm = { "name" => name, "VMState" => "poweroff", "nic1" => "nat",
             "nic2" => "bridged", "nic3" => "hostonly", "macaddress2" => "080027A1B2C3",
             "forwards" => ["imported,tcp,,2222,,22"] }
      File.write("vm.yml", YAML.dump(vm))
    when "showvminfo"
      vm.reject { |key, _| key == "forwards" }.each { |key, value| puts %(#{key}="#{value}") }
      vm.fetch("forwards").each_with_index { |rule, index| puts %(Forwarding(#{index})="#{rule}") }
    when "modifyvm"
      abort "VM must be stopped" unless vm.fetch("VMState") == "poweroff"

      if options.include?("--intnet2") && File.exist?("fail-before-attach")
        File.delete("fail-before-attach")
        abort "simulated failure before attaching the adapter"
      end

      until options.empty?
        option, value = options.shift(2)
        case option
        when "--nat-pf1"
          if value == "delete"
            name = options.shift
            vm.fetch("forwards").reject! { |rule| rule.split(",").first == name }
          else
            vm.fetch("forwards") << value
          end
        when "--nic1", "--nic2", "--nic3", "--intnet2", "--cable-connected2"
          vm[option.delete_prefix("--")] = value
        else
          abort "Unexpected modifyvm option #{option}"
        end
      end
      File.write("vm.yml", YAML.dump(vm))
      if vm["nic2"] == "intnet" && File.exist?("fail-after-attach")
        File.delete("fail-after-attach")
        abort "simulated failure after attaching the adapter"
      end
    when "startvm", "controlvm"
      vm["VMState"] = command == "startvm" ? "running" : "poweroff"
      File.write("vm.yml", YAML.dump(vm))
    when "unregistervm"
      abort "Expected VM deletion" unless options == ["--delete"] && vm.fetch("VMState") == "poweroff"

      File.delete("vm.yml")
    else
      abort "Unexpected VBoxManage call #{command}"
    end
  RUBY
  File.chmod(0o700, vbox)

  File.write(File.join(root, "metadata.json"), '{"provider":"virtualbox"}')
  File.write(File.join(root, "box.ovf"), "")
  archive = File.join(root, "test.box")
  abort "Could not create test box" unless system("/usr/bin/tar", "-cf", archive, "-C", root, "metadata.json", "box.ovf")

  config = File.join(root, "kitchen.yml")
  default_config = <<~YAML
    driver:
      name: virtualbox
      vboxmanage: #{vbox}
      box: #{archive}
      insert_key: false
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
  state_path = File.join(root, ".kitchen", "#{name}.yml")
  vm_path = File.join(root, "vm.yml")
  state = -> { YAML.safe_load_file(state_path) }
  vm = -> { YAML.safe_load_file(vm_path) }
  kitchen = [RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), Gem.bin_path("test-kitchen", "kitchen")]
  invoke = lambda do |action, error: nil|
    output, result = Open3.capture2e(*kitchen, action, name, chdir: root)
    log = File.join(root, ".kitchen", "logs", "#{name}.log")
    output += File.read(log) if !result.success? && File.file?(log)
    abort output unless error ? !result.success? && output.include?(error) : result.success?
    output
  end
  destroy = lambda do
    invoke.call("destroy")
    abort "VM or state remains after destroy" if File.exist?(vm_path) || File.exist?(state_path)
    abort "VM files remain after destroy" unless Dir.glob(File.join(root, ".kitchen", "virtualbox-*")).empty?
  end

  File.write(config, default_config)
  invoke.call("create")
  ssh_port = state.call.fetch("port")
  abort "Default SSH endpoint changed" unless state.call.fetch("hostname") == "127.0.0.1" &&
    vm.call.fetch("forwards") == ["kitchen-ssh,tcp,127.0.0.1,#{ssh_port},,22"]
  abort "Default adapters changed" unless vm.call.values_at("nic1", "nic2", "nic3") == %w{nat bridged hostonly}
  destroy.call

  TCPServer.open("127.0.0.1", 0) do |listener|
    host_port = listener.addr[1]
    private_config = default_config.sub("  insert_key: false\n", <<~YAML.lines.map { |line| "  #{line}" }.join)
      insert_key: false
      port_forward: { host_port: #{host_port}, guest_port: 8080 }
      private_network: kitchen-test
      private_address: 192.0.2.31/24
    YAML
    File.write(config, private_config)
    invoke.call("create", error: "Could not bind VirtualBox port forward on 127.0.0.1:#{host_port}")
    token = state.call.fetch("virtualbox_token")
    abort "VM changed with occupied port" unless vm.call.values_at("VMState", "nic2") == %w{poweroff bridged}
    listener.close

    File.write(File.join(root, "fail-before-attach"), "")
    invoke.call("create", error: "simulated failure before attaching the adapter")
    abort "Failed attachment was recorded as applied" if state.call.key?("virtualbox_private_network")

    private_config = private_config.sub("private_network: kitchen-test", "private_network: kitchen-corrected")
    File.write(config, private_config)
    File.write(File.join(root, "fail-after-attach"), "")
    invoke.call("create", error: "simulated failure after attaching the adapter")
    File.write(config, default_config)
    invoke.call("create", error: "different private networking settings")
    abort "VM booted with an interrupted private setup" unless vm.call.fetch("VMState") == "poweroff"

    File.write(config, private_config)
    output = invoke.call("create")
    abort "Static IPv4 was not configured" unless output.include?("ip -4 address replace 192.0.2.31/24")
    abort "Incorrect private adapters" unless vm.call.values_at("nic1", "nic2", "intnet2", "nic3", "cable-connected2") ==
      %w{nat intnet kitchen-corrected none on}
    abort "Retry replaced the VM" unless state.call.fetch("virtualbox_token") == token
    abort "Private settings were not checkpointed" unless state.call.values_at("virtualbox_private_network", "virtualbox_private_address") ==
      ["kitchen-corrected", "192.0.2.31/24"] && !state.call.key?("virtualbox_pending_private_settings")
    ssh_port = state.call.fetch("port")
    abort "Incorrect loopback forwards" unless host_port != ssh_port && vm.call.fetch("forwards") ==
      ["kitchen-ssh,tcp,127.0.0.1,#{ssh_port},,22", "kitchen-forward,tcp,127.0.0.1,#{host_port},,8080"]

    invoke.call("create")
    abort "SSH endpoint changed on reuse" unless state.call.values_at("hostname", "port") == ["127.0.0.1", ssh_port]

    File.write(config, private_config.sub("guest_port: 8080", "guest_port: 8081"))
    invoke.call("create", error: "different networking settings")
    File.write(config, private_config.sub("192.0.2.31/24", "192.0.2.999/24"))
    invoke.call("create", error: "requires a valid IPv4 CIDR address")
    destroy.call
  end
end
