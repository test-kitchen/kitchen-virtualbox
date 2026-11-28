# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "json"

registry_path = ENV.fetch("VBOX_TEST_REGISTRY")
registry = JSON.parse(File.read(registry_path))
disks_path = File.join(File.dirname(registry_path), "disks.json")
command, target, *options = ARGV
uuid = registry.key?(target) ? target : registry.find { |_, vm| vm.fetch("name") == target }&.first

case command
when "list"
  abort "unexpected list target" unless %w{vms hdds}.include?(target)

  registry.each { |id, vm| puts %("#{vm.fetch("name")}" {#{id}}) } if target == "vms"
  if target == "hdds"
    JSON.parse(File.read(disks_path)).each do |id, path|
      puts "UUID: #{id}", "Location: #{path}", ""
    end
  end
when "showvminfo"
  vm = registry.fetch(uuid)
  puts %{UUID="#{uuid}"}
  puts %{VMState="#{vm.fetch("state")}"}
  puts 'nic1="nat"'
  puts %{nic2="#{vm.fetch("nic2", "none")}"}
  puts %{Forwarding(0)="#{vm["forwarding1"]},tcp,,8080,,80"} if vm["forwarding1"]
  if vm["nic2"] == "nat" && vm["forwarding2"]
    puts %{Forwarding(0)="#{vm["forwarding2"]},tcp,,8081,,80"}
  end
  puts %{SharedFolderNameMachineMapping1="#{vm.fetch("share")}"} if vm.key?("share")
when "clonevm"
  abort "attempted to clone a running source" unless registry.fetch(uuid).fetch("state") == "poweroff"
  abort "expected a registered clone" unless options.include?("--register") &&
    options.each_cons(2).include?(%w{--mode machine})
  if !registry.fetch(uuid)["snapshot"] && options.any? { |option| option.start_with?("--options") }
    abort "expected a full clone without options"
  end

  clone_uuid = options.fetch(options.index("--uuid") + 1)
  abort "clone already registered" if registry.key?(clone_uuid)

  name = options.fetch(options.index("--name") + 1)
  registry[clone_uuid] = registry.fetch(uuid).merge("name" => name, "source" => uuid)
  if (snapshot = registry.fetch(uuid)["snapshot"])
    abort "expected a linked clone of the explicit snapshot" unless
      options.include?("--options=Link") && options.include?("--snapshot=#{snapshot}")
    registry[clone_uuid]["linked_snapshot"] = snapshot
    directory = File.realpath(options.fetch(options.index("--basefolder") + 1))
    clone_disk = File.join(directory, "clone.vmdk")
    File.write(clone_disk, "")
    source_disk = File.join(File.dirname(registry_path), "source.vmdk")
    File.write(disks_path, JSON.generate(uuid => source_disk, clone_uuid => clone_disk))
  else
    abort "expected a full clone" if options.include?("--options=Link")
  end
  File.write(registry_path, JSON.generate(registry))
  failure_marker = File.join(File.dirname(registry_path), "fail_clone_once")
  if File.exist?(failure_marker)
    File.delete(failure_marker)
    abort "simulated clone failure"
  end
when "modifyvm"
  vm = registry.fetch(uuid)
  index = options.index("--nic2")
  vm["nic2"] = options.fetch(index + 1) if index
  if vm["source"] && options.include?("--vrde")
    expected = { "--vrde" => "off", "--clipboard-mode" => "disabled", "--drag-and-drop" => "disabled",
                 "--usb-ohci" => "off", "--usb-ehci" => "off", "--usb-xhci" => "off",
                 "--nic1" => "nat", "--cable-connected1" => "on" }
    abort "missing clone isolation options" unless expected.all? { |key, value| options.each_cons(2).include?([key, value]) }
    vm["cable1"] = "on"
  end
  if (index = options.index("--nat-pf1"))
    rule = options.fetch(index + 1)
    if rule == "delete"
      abort "forwarding rule belongs to another adapter" unless options.fetch(index + 2) == vm["forwarding1"]
      vm.delete("forwarding1")
    else
      abort "expected loopback SSH forwarding" unless rule.start_with?("kitchen-ssh,tcp,127.0.0.1,")
    end
  end
when "sharedfolder"
  id, name_option, share = options
  abort "unexpected shared folder operation" unless target == "remove" && name_option == "--name"
  abort "unknown shared folder" unless registry.fetch(id).delete("share") == share
when "startvm"
  abort "clone network cable disconnected" if registry.fetch(uuid)["cable1"] == "off"
  registry.fetch(uuid)["state"] = "running"
when "controlvm"
  registry.fetch(uuid)["state"] = "poweroff"
when "unregistervm"
  abort "linked clone teardown must preserve shared media" if registry.fetch(uuid)["linked_snapshot"] && options.include?("--delete")
  registry.delete(uuid)
when "closemedium"
  abort "expected a disk" unless target == "disk"

  failure_marker = File.join(File.dirname(registry_path), "fail_close_once")
  if File.exist?(failure_marker)
    File.delete(failure_marker)
    abort "simulated disk close failure"
  end

  disks = JSON.parse(File.read(disks_path))
  abort "unknown disk" unless disks.delete(options.fetch(0))

  File.write(disks_path, JSON.generate(disks))
else
  abort "unexpected VBoxManage command #{ARGV.inspect}"
end

File.write(registry_path, JSON.generate(registry))
