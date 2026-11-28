# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "open3"
require "tmpdir"
require "yaml"

transport, scheme, listener_port, port_override = ARGV
ssh = transport == "ssh"
platform = ssh ? "linux" : "windows"
rule_name = ssh ? "kitchen-ssh" : "kitchen-winrm"
port_config = "port: #{port_override}" if port_override
create_command = ssh ? "touch fixture-converged" : "New-Item -Path fixture-converged"
verify_command = ssh ? "test -f fixture-converged" : "Get-Item -Path fixture-converged"

Dir.mktmpdir("kitchen-virtualbox-lifecycle") do |root|
  uuid = "9135d992-4a17-4748-99cd-b51c04080b28"
  vbox = File.join(root, "VBoxManage")
  File.write(vbox, <<~RUBY)
    #!#{RbConfig.ruby}
    require "fileutils"
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
        abort "Unexpected forwarding rule: \#{rule}" unless /\\A#{rule_name},tcp,127\\.0\\.0\\.1,\\d+,,#{listener_port}\\z/.match?(rule)
        File.write("forwarding", rule)
      end
    when "startvm"
      abort "Already running" if File.exist?("running")
      File.write("running", "")
    when "guestcontrol"
      abort "Unexpected SSH bootstrap" unless #{ssh} && ARGV[1, 4] == ["#{uuid}", "run", "--username", "vagrant"]
      public_key = ARGV.last
      abort "Missing generated public key" unless public_key.start_with?("ssh-ed25519 ")
      File.write("installed-key", public_key)
    when "controlvm"
      abort "Unexpected poweroff" unless ARGV == ["controlvm", "#{uuid}", "poweroff"]
      File.delete("running")
    when "unregistervm"
      abort "Unexpected unregister" unless ARGV == ["unregistervm", "#{uuid}", "--delete"]
      File.delete("registered")
      FileUtils.rm_f(%w{forwarding removed-image-rule installed-key fixture-converged fixture-verified})
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

  transport_config = unless ssh
                       <<~YAML
                         transport:
                           name: winrm
                           winrm_transport: #{transport}
                           no_ssl_peer_verification: false
                           username: fixture-user
                           password: fixture-password
                           #{port_config}
                       YAML
                     end
  File.write(File.join(root, "kitchen.yml"), <<~YAML)
    driver:
      name: virtualbox
      box: windows.box
      vboxmanage: #{vbox}
    #{transport_config}
    provisioner:
      name: shell
      command: #{create_command}
    verifier:
      name: shell
      remote_exec: true
      command: #{verify_command}
    platforms:
      - name: #{platform}
        os_type: #{platform == "linux" ? "unix" : "windows"}
        shell_type: #{ssh ? "bourne" : "powershell"}
    suites:
      - name: default
  YAML

  # Keep Kitchen's transport configuration and replace guest I/O.
  guest = File.join(root, "guest.rb")
  File.write(guest, <<~RUBY)
    require "kitchen/transport/#{ssh ? "ssh" : "winrm"}"
    module Guest
      def check_endpoint
        port = File.read("forwarding").split(",").fetch(3)
        if #{ssh}
          abort "Unexpected SSH endpoint" unless hostname == "127.0.0.1" && options[:port] == port.to_i
          abort "Unexpected SSH identity" unless username == "vagrant" &&
            File.file?(options.fetch(:keys).first) && File.file?("installed-key")
        else
          abort "Unexpected WinRM endpoint" unless options[:endpoint] == "#{scheme}://127.0.0.1:\#{port}/wsman"
          abort "Unexpected WinRM identity" unless options[:user] == "fixture-user"
          abort "TLS verification disabled" if #{scheme == "https"} && options[:no_ssl_peer_verification] != false
        end
      end

      def wait_until_ready
        check_endpoint
        if !#{ssh} && !File.exist?("ready")
          raise Kitchen::Transport::WinrmFailed, "Fixture listener is unavailable"
        end
      end

      def execute(script)
        return if script.nil?

        check_endpoint
        if script.include?("#{create_command}")
          File.write("fixture-converged", "")
        elsif script == "#{verify_command}"
          abort "Verify ran before converge" unless File.file?("fixture-converged")
          File.write("fixture-verified", "")
        else
          abort "Unexpected guest command: \#{script}"
        end
      end

      def upload(*)
        check_endpoint
      end

      def close; end
      def cleanup!; end
    end
    Kitchen::Transport::#{ssh ? "Ssh" : "Winrm"}::Connection.prepend(Guest)
  RUBY

  instance = "default-#{platform}"
  state_path = File.join(root, ".kitchen", "#{instance}.yml")
  kitchen = [RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-r", guest, Gem.bin_path("test-kitchen", "kitchen")]
  invoke = lambda do |action|
    output, result = Open3.capture2e(*kitchen, action, instance, chdir: root)
    log = File.join(root, ".kitchen", "logs", "#{instance}.log")
    output += File.read(log) if !result.success? && File.file?(log)
    [output, result]
  end

  unless ssh
    secondary_nic = File.join(root, "secondary-nic")
    File.write(secondary_nic, "")
    output, result = invoke.call("create")
    abort output unless !result.success? && output.include?("only its first network adapter")
    abort "VM with an extra adapter was started" if File.exist?(File.join(root, "running"))
    File.delete(secondary_nic)

    expect_listener_outage = lambda do
      output, result = invoke.call("create")
      abort output unless !result.success? && output.include?("Fixture listener is unavailable")
      abort "VM ownership was lost" unless YAML.safe_load_file(state_path)["virtualbox_uuid"] == uuid
    end
    expect_listener_outage.call
    output, result = invoke.call("destroy")
    abort output unless result.success?
    if %w{registered running}.any? { |name| File.exist?(File.join(root, name)) } || File.exist?(state_path)
      abort "VM or Kitchen state survived immediate destroy"
    end

    expect_listener_outage.call
    failed_forward = File.read(File.join(root, "forwarding"))
    File.write(File.join(root, "ready"), "")
  end

  output, result = invoke.call("create")
  abort output unless result.success?
  abort "Imported forwarding rule survived" unless File.file?(File.join(root, "removed-image-rule"))
  state = YAML.safe_load_file(state_path)
  abort "Retry replaced the forwarding rule" if failed_forward && File.read(File.join(root, "forwarding")) != failed_forward
  port = File.read(File.join(root, "forwarding")).split(",").fetch(3).to_i
  abort "Wrong recovered endpoint" unless state.values_at("hostname", "port") == ["127.0.0.1", port]
  abort "Credentials were persisted" if state.key?("password") || (!ssh && state.key?("ssh_key"))

  %w{converge verify}.each do |action|
    output, result = invoke.call(action)
    abort output unless result.success?
  end
  abort "Verifier did not reach the guest" unless File.file?(File.join(root, "fixture-verified"))

  output, result = invoke.call("destroy")
  abort output unless result.success?
  abort "VM or Kitchen state survived destroy" if File.exist?(File.join(root, "registered")) || File.exist?(state_path)
  abort "Instance directory survived destroy" unless Dir.glob(File.join(root, ".kitchen", "virtualbox-*")).empty?
  abort "Source box was altered" unless File.binread(box) == original_box
end
