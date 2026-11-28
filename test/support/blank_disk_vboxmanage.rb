# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "json"

UUID = "11111111-1111-4111-8111-111111111111".freeze
MEDIUM_UUID = "22222222-2222-4222-8222-222222222222".freeze

def argument(key)
  ARGV.fetch(ARGV.index(key) + 1)
end

vm = File.file?("vm.json") ? JSON.parse(File.read("vm.json")) : nil
medium = File.read("medium.json") if File.file?("medium.json")
case ARGV.first(2)
when %w{list vms}
  puts %("#{vm.fetch("name")}" {#{UUID}}) if vm
when %w{list hdds}
  puts "UUID: #{MEDIUM_UUID}\nLocation: #{medium}\n\n" if medium
else
  case ARGV.first
  when "import"
    boot = File.join(argument("--basefolder"), "boot.vdi")
    File.write(boot, "boot disk")
    vm = { "name" => argument("--vmname"), "state" => "poweroff",
           "disks" => { "Storage-0-0" => boot, "Storage-1-0" => File.expand_path("external.vdi") } }
  when "showvminfo"
    puts %{VMState="#{vm.fetch("state")}"}
    puts 'storagecontrollername0="Storage"', 'storagecontrollertype0="VirtioSCSI"', 'storagecontrollermaxportcount0="3"'
    puts %{storagecontrollerportcount0="#{vm.fetch("ports", 2)}"}
    vm.fetch("disks").each { |slot, path| puts %{"#{slot}"="#{path}"} }
    puts %{Forwarding(0)="#{vm.fetch("forwarding")}"} if vm.key?("forwarding")
  when "storagectl"
    vm["ports"] = Integer(argument("--portcount"))
  when "createmedium"
    path = argument("--filename")
    abort "disk already exists" if File.exist?(path)
    File.write(path, argument("--size"))
    File.write("medium.json", path)
  when "storageattach"
    slot = "#{argument("--storagectl")}-#{argument("--port")}-#{argument("--device")}"
    path = argument("--medium")
    if path == "none"
      vm.fetch("disks").delete(slot)
    else
      if File.exist?("fail-attach-once")
        File.delete("fail-attach-once")
        abort "simulated attach failure"
      end
      abort "occupied slot" if vm.fetch("disks").key?(slot)
      abort "invalid port" if Integer(argument("--port")) >= vm.fetch("ports", 2)
      vm.fetch("disks")[slot] = path
    end
  when "modifyvm"
    vm["forwarding"] = argument("--nat-pf1")
  when "startvm"
    vm["state"] = "running"
  when "controlvm"
    vm["state"] = "poweroff"
  when "unregistervm"
    vm.fetch("disks").each_value do |disk_path|
      File.delete(disk_path)
      File.delete("medium.json") if disk_path == medium
    end
    File.delete("vm.json")
    vm = nil
  when "closemedium"
    abort "unknown medium" unless ARGV.fetch(2) == MEDIUM_UUID
    File.delete("medium.json")
  else
    abort "Unexpected command #{ARGV.inspect}"
  end
end
File.write("vm.json", JSON.generate(vm)) if vm
