# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

uuid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
token = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
snapshot = "cccccccc-cccc-cccc-cccc-cccccccccccc"
online_snapshot = "dddddddd-dddd-dddd-dddd-dddddddddddd"
retired_share_snapshot = "11111111-1111-1111-1111-111111111111"
changed_share_snapshot = "22222222-2222-2222-2222-222222222222"
name = "kitchen-default-linux-#{token}"
lib = File.expand_path("../lib", __dir__)
cli = File.expand_path("../exe/kitchen-virtualbox-restore", __dir__)

Dir.mktmpdir("kitchen-virtualbox-restore-") do |root|
  FileUtils.mkdir_p(File.join(root, "state"))
  File.symlink("state", File.join(root, ".kitchen"))
  vm_dir = File.join(root, ".kitchen", "virtualbox-#{token}", name)
  FileUtils.mkdir_p(vm_dir)
  vm_config = File.join(vm_dir, "#{name}.vbox")
  File.write(vm_config, <<~XML)
    <VirtualBox xmlns="http://www.virtualbox.org/">
      <Machine>
        <Hardware><SharedFolders>
          <SharedFolder name="kitchen-0123456789abcdef" hostPath="/inherited" writable="false"/>
        </SharedFolders></Hardware>
        <Snapshot uuid="{#{snapshot}}">
          <Hardware><SharedFolders>
            <SharedFolder name="kitchen-0123456789abcdef" hostPath="/inherited" writable="false"/>
            <SharedFolder name="user-share" hostPath="/user"/>
          </SharedFolders></Hardware>
          <Snapshots>
            <Snapshot uuid="{#{online_snapshot}}" stateFile="Snapshots/online.sav"/>
            <Snapshot uuid="{#{retired_share_snapshot}}">
              <Hardware><SharedFolders>
                <SharedFolder name="kitchen-fedcba9876543210" hostPath="/retired" writable="true"/>
              </SharedFolders></Hardware>
            </Snapshot>
            <Snapshot uuid="{#{changed_share_snapshot}}">
              <Hardware><SharedFolders>
                <SharedFolder name="kitchen-0123456789abcdef" hostPath="/inherited" writable="true"/>
              </SharedFolders></Hardware>
            </Snapshot>
          </Snapshots>
        </Snapshot>
      </Machine>
    </VirtualBox>
  XML
  backend = File.join(root, "vbox")
  File.write(backend, <<~RUBY)
    #!#{RbConfig.ruby}
    case ARGV
    when ["showvminfo", "#{uuid}", "--machinereadable"]
      puts %Q(name="#{name}")
      puts %Q(UUID="#{uuid}")
      puts %Q(CfgFile="\#{ENV.fetch("VM_CONFIG")}")
      puts %Q(VMState="\#{ENV.fetch("VM_STATE", "poweroff")}")
    when ["snapshot", "#{uuid}", "restore", "#{snapshot}"]
      abort "interrupted restore" if ENV["INTERRUPT_RESTORE"]
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
  state = YAML.dump("virtualbox_uuid" => uuid, "virtualbox_token" => token, "virtualbox_name" => name,
    "hostname" => "127.0.0.1", "port" => 2222, "last_action" => "converge")
  File.write(state_file, state)

  verify = lambda do |requested, error, changed: false, **environment|
    output, status = Open3.capture2e({ "VM_CONFIG" => vm_config }.merge(environment),
      RbConfig.ruby, "-I", lib, cli, "default-linux", requested, chdir: root)
    restored = File.exist?(File.join(root, "restored"))
    unless error ? !status.success? && !restored && output.include?(error) : status.success? && restored
      abort "Unexpected restore result: #{output}"
    end
    if changed
      expected = YAML.safe_load(state).reject { |key, _| %w{hostname port last_action}.include?(key) }
      expected["virtualbox_restore_pending"] = true
      abort "Kitchen did not invalidate the stale endpoint" unless YAML.load_file(state_file) == expected
    else
      abort "Kitchen state changed" unless File.read(state_file) == state
    end
  end

  verify.call("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", "Snapshot does not exist")
  verify.call(online_snapshot, "while the guest is powered off")
  verify.call(retired_share_snapshot, "ambiguous VirtualBox shared folder: kitchen-fedcba9876543210")
  verify.call(changed_share_snapshot, "ambiguous VirtualBox shared folder: kitchen-0123456789abcdef")
  verify.call(snapshot, "powered off", "VM_STATE" => "running")
  verify.call(snapshot, "Kitchen-managed VirtualBox VM", "VM_CONFIG" => state_file)
  File.symlink(state_file, File.join(vm_dir, "foreign.vbox"))
  verify.call(snapshot, "Kitchen-managed VirtualBox VM", "VM_CONFIG" => File.join(vm_dir, "foreign.vbox"))
  File.rename(File.join(root, "kitchen.yml"), File.join(root, "snapshot.yml"))
  verify.call(snapshot, "interrupted restore", changed: true, "KITCHEN_YAML" => "snapshot.yml", "INTERRUPT_RESTORE" => "1")
  output, status = Open3.capture2e({ "KITCHEN_YAML" => "snapshot.yml" },
    RbConfig.ruby, "-I", lib, Gem.bin_path("test-kitchen", "kitchen"), "exec", "default-linux", "-c", "true", chdir: root)
  abort "Kitchen exec did not reject the stale endpoint: #{output}" if status.success? || !output.include?("Run kitchen create")
  verify.call(snapshot, nil, changed: true, "KITCHEN_YAML" => "snapshot.yml")
end
