# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

uuid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
token = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
snapshot = "cccccccc-cccc-cccc-cccc-cccccccccccc"
name = "kitchen-default-linux-#{token}"
lib = File.expand_path("../lib", __dir__)
cli = File.expand_path("../exe/kitchen-virtualbox-restore", __dir__)

Dir.mktmpdir("kitchen-virtualbox-restore-") do |root|
  vm_dir = File.join(root, ".kitchen", "virtualbox-#{token}", name)
  FileUtils.mkdir_p(vm_dir)
  vm_config = File.join(vm_dir, "#{name}.vbox")
  File.write(vm_config, "")
  backend = File.join(root, "vbox")
  File.write(backend, <<~RUBY)
    #!#{RbConfig.ruby}
    case ARGV
    when ["showvminfo", "#{uuid}", "--machinereadable"]
      puts %Q(name="#{name}")
      puts %Q(UUID="#{uuid}")
      puts %Q(CfgFile="\#{ENV.fetch("VM_CONFIG")}")
      puts %Q(VMState="\#{ENV.fetch("VM_STATE", "poweroff")}")
    when ["snapshot", "#{uuid}", "list", "--machinereadable"]
      puts %Q(SnapshotUUID="#{snapshot}")
    when ["snapshot", "#{uuid}", "restore", "#{snapshot}"]
      File.write("restored", "#{snapshot}")
    else
      abort "Unexpected VBoxManage call: \#{ARGV.inspect}"
    end
  RUBY
  File.chmod(0o700, backend)
  File.write(File.join(root, "kitchen.yml"), YAML.dump(
    "driver" => { "name" => "virtualbox", "vboxmanage" => backend },
    "provisioner" => { "name" => "dummy" },
    "platforms" => [{ "name" => "linux" }],
    "suites" => [{ "name" => "default" }]
  ))
  state_file = File.join(root, ".kitchen", "default-linux.yml")
  state = YAML.dump("virtualbox_uuid" => uuid, "virtualbox_token" => token, "virtualbox_name" => name)
  File.write(state_file, state)

  verify = lambda do |requested, error, **environment|
    output, status = Open3.capture2e({ "VM_CONFIG" => vm_config }.merge(environment),
      RbConfig.ruby, "-I", lib, cli, "default-linux", requested, chdir: root)
    restored = File.exist?(File.join(root, "restored"))
    unless error ? !status.success? && !restored && output.include?(error) : status.success? && restored
      abort "Unexpected restore result: #{output}"
    end
    abort "Kitchen state changed" unless File.read(state_file) == state
  end

  verify.call("dddddddd-dddd-dddd-dddd-dddddddddddd", "Snapshot does not exist")
  verify.call(snapshot, "powered off", "VM_STATE" => "running")
  verify.call(snapshot, "Kitchen-managed VirtualBox VM", "VM_CONFIG" => state_file)
  File.rename(File.join(root, "kitchen.yml"), File.join(root, "snapshot.yml"))
  verify.call(snapshot, nil, "KITCHEN_YAML" => "snapshot.yml")
end
