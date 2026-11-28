# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "open3"
require "tmpdir"
require "yaml"

transport, scheme, listener_port = ARGV

Dir.mktmpdir("kitchen-virtualbox-winrm") do |root|
  uuid = "9135d992-4a17-4748-99cd-b51c04080b28"
  vbox = File.join(root, "VBoxManage")
  File.write(vbox, <<~RUBY)
    #!#{RbConfig.ruby}
    case ARGV.first
    when "list"
      puts File.read("registered") if File.file?("registered")
    when "import"
      abort "Already imported" if File.exist?("registered")
      File.write("registered", %Q{"\#{ARGV.fetch(ARGV.index("--vmname") + 1)}" {#{uuid}}})
    when "showvminfo"
      puts File.exist?("running") ? 'VMState="running"' : 'VMState="poweroff"'
      puts File.exist?("secondary-nic") ? 'nic2="bridged"' : 'nic2="none"'
      puts 'Forwarding(0)="image-rule,tcp,0.0.0.0,5985,,5985"' unless File.exist?("removed-image-rule")
      puts %Q{Forwarding(0)="\#{File.read("forwarding")}"} if File.file?("forwarding")
    when "modifyvm"
      rule = ARGV.fetch(ARGV.index("--nat-pf1") + 1)
      if rule == "delete=image-rule"
        File.write("removed-image-rule", "")
      else
        abort "Unexpected forwarding rule: \#{rule}" unless /\\Akitchen-winrm,tcp,127\\.0\\.0\\.1,\\d+,,#{listener_port}\\z/.match?(rule)
        File.write("forwarding", rule)
      end
    when "startvm"
      abort "Already running" if File.exist?("running")
      File.write("running", "")
    when "controlvm"
      abort "Unexpected poweroff" unless ARGV == ["controlvm", "#{uuid}", "poweroff"]
      File.delete("running")
    when "unregistervm"
      abort "Unexpected unregister" unless ARGV == ["unregistervm", "#{uuid}", "--delete"]
      File.delete("registered")
    else
      abort "Unexpected VBoxManage call: \#{ARGV.inspect}"
    end
  RUBY
  File.chmod(0o700, vbox)

  File.write(File.join(root, "metadata.json"), '{"provider":"virtualbox"}')
  File.write(File.join(root, "box.ovf"), "<fixture/>")
  box = File.join(root, "windows.box")
  abort "Could not build test box" unless system("/usr/bin/tar", "-cf", box, "-C", root, "metadata.json", "box.ovf")
  original_box = File.binread(box)

  File.write(File.join(root, "kitchen.yml"), <<~YAML)
    driver:
      name: virtualbox
      box: windows.box
      vboxmanage: #{vbox}
    transport:
      name: winrm
      winrm_transport: #{transport}
      username: fixture-user
      password: fixture-password
    provisioner:
      name: dummy
    platforms:
      - name: windows
        os_type: windows
    suites:
      - name: default
  YAML

  # Simulate only guest readiness. Kitchen still builds its actual WinRM connection.
  guest = File.join(root, "guest.rb")
  File.write(guest, <<~RUBY)
    require "kitchen/transport/winrm"
    module Guest
      def wait_until_ready
        port = File.read("forwarding").split(",").fetch(3)
        abort "Unexpected WinRM endpoint" unless options[:endpoint] == "#{scheme}://127.0.0.1:\#{port}/wsman"
        abort "Unexpected WinRM identity" unless options[:user] == "fixture-user"
        raise Kitchen::Transport::WinrmFailed, "Fixture guest is unavailable" unless File.exist?("ready")
      end
    end
    Kitchen::Transport::Winrm::Connection.prepend(Guest)
  RUBY

  state_path = File.join(root, ".kitchen", "default-windows.yml")
  kitchen = [RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-r", guest, Gem.bin_path("test-kitchen", "kitchen")]
  invoke = lambda do |action|
    output, result = Open3.capture2e(*kitchen, action, "default-windows", chdir: root)
    log = File.join(root, ".kitchen", "logs", "default-windows.log")
    output += File.read(log) if !result.success? && File.file?(log)
    [output, result]
  end

  secondary_nic = File.join(root, "secondary-nic")
  File.write(secondary_nic, "")
  output, result = invoke.call("create")
  abort output unless !result.success? && output.include?("only its first network adapter")
  abort "VM with an extra adapter was started" if File.exist?(File.join(root, "running"))
  File.delete(secondary_nic)

  output, result = invoke.call("create")
  abort output unless !result.success? && output.include?("Fixture guest is unavailable")
  abort "Imported forwarding rule survived" unless File.file?(File.join(root, "removed-image-rule"))
  abort "VM ownership was lost" unless YAML.safe_load_file(state_path)["virtualbox_uuid"] == uuid

  File.write(File.join(root, "ready"), "")
  output, result = invoke.call("create")
  abort output unless result.success?
  state = YAML.safe_load_file(state_path)
  port = File.read(File.join(root, "forwarding")).split(",").fetch(3).to_i
  abort "Wrong recovered endpoint" unless state.values_at("hostname", "port") == ["127.0.0.1", port]
  abort "Credentials were persisted" if state.key?("password") || state.key?("ssh_key")

  output, result = invoke.call("destroy")
  abort output unless result.success?
  abort "VM or Kitchen state survived destroy" if File.exist?(File.join(root, "registered")) || File.exist?(state_path)
  abort "Source box was altered" unless File.binread(box) == original_box
end
