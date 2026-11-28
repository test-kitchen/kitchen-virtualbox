# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "json"
require "securerandom"

def argument(key)
  ARGV.fetch(ARGV.index(key) + 1)
end

vm = File.file?("vm.json") ? JSON.parse(File.read("vm.json")) : nil
media = File.file?("media.json") ? JSON.parse(File.read("media.json")) : {}
case ARGV.first(2)
when %w{list vms}
  puts %("#{vm.fetch("name")}" {#{vm.fetch("uuid")}}) if vm
when %w{list hdds}
  media.each { |id, path| puts "UUID: #{id}\nParent UUID: base\nLocation: #{path}\n\n" }
else
  case ARGV.first
  when "import"
    boot = File.join(argument("--basefolder"), "boot.vdi")
    File.write(boot, "boot disk")
    media[SecureRandom.uuid] = boot
    vm = { "name" => argument("--vmname"), "state" => "poweroff", "uuid" => SecureRandom.uuid,
           "disks" => { "Storage-0-0" => boot, "Storage-1-0" => File.expand_path("external.vdi") } }
  when "snapshot"
    if vm.key?("snapshot_disks")
      puts 'SnapshotName="snapshot with foreign disk"'
    else
      puts "This machine does not have any snapshots"
      exit 1
    end
  when "showvminfo"
    puts %{VMState="#{vm.fetch("state")}"}
    puts 'storagecontrollername0="Storage"', 'storagecontrollertype0="VirtioSCSI"', 'storagecontrollermaxportcount0="3"'
    puts %{storagecontrollerportcount0="#{vm.fetch("ports", 2)}"}
    vm.fetch("disks").each do |slot, path|
      puts %{"#{slot}"="#{path}"}
      puts %{"#{slot.sub(/-\d+-\d+$/, '-ImageUUID\&')}"="#{media.key(path)}"} if media.value?(path)
    end
    puts %{Forwarding(0)="#{vm.fetch("forwarding")}"} if vm.key?("forwarding")
  when "storagectl"
    vm["ports"] = Integer(argument("--portcount"))
  when "createmedium"
    path = argument("--filename")
    abort "disk already exists" if File.exist?(path)
    File.write(path, argument("--size"))
    media[SecureRandom.uuid] = path
  when "storageattach"
    slot = "#{argument("--storagectl")}-#{argument("--port")}-#{argument("--device")}"
    id = argument("--medium")
    if id == "none"
      vm.fetch("disks").delete(slot)
    else
      if File.exist?("fail-attach-once")
        File.delete("fail-attach-once")
        abort "simulated attach failure"
      end
      abort "occupied slot" if vm.fetch("disks").key?(slot)
      abort "invalid port" if Integer(argument("--port")) >= vm.fetch("ports", 2)
      vm.fetch("disks")[slot] = media.fetch(id)
    end
  when "modifyvm"
    vm["forwarding"] = argument("--nat-pf1")
  when "startvm"
    vm["state"] = "running"
  when "controlvm"
    vm["state"] = "poweroff"
  when "unregistervm"
    (vm.fetch("disks").values + vm.fetch("snapshot_disks", [])).uniq.each do |disk_path|
      File.delete(disk_path)
      media.delete(media.key(disk_path))
    end
    File.delete("vm.json")
    vm = nil
  when "closemedium"
    File.delete(media.delete(ARGV.fetch(2))) if ARGV.include?("--delete")
  else
    abort "Unexpected command #{ARGV.inspect}"
  end
end
File.write("vm.json", JSON.generate(vm)) if vm
File.write("media.json", JSON.generate(media))
