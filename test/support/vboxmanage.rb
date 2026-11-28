# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "json"

registry_path = ENV.fetch("VBOX_TEST_REGISTRY")
registry = JSON.parse(File.read(registry_path))
command, target, *options = ARGV
uuid = registry.key?(target) ? target : registry.find { |_, vm| vm.fetch("name") == target }&.first

case command
when "list"
  abort "unexpected list target" unless %w{vms hdds}.include?(target)

  registry.each { |id, vm| puts %("#{vm.fetch("name")}" {#{id}}) } if target == "vms"
when "showvminfo"
  vm = registry.fetch(uuid)
  puts %{UUID="#{uuid}"}
  puts %{VMState="#{vm.fetch("state")}"}
  puts 'nic1="nat"'
  puts %{nic2="#{vm.fetch("nic2", "none")}"}
  puts %{Forwarding(0)="#{vm["forwarding1"]},tcp,,8080,,80"} if vm["forwarding1"]
  if vm["forwards"]
    vm.fetch("forwards").each_with_index { |rule, index| puts %{Forwarding(#{index})="#{rule}"} }
  end
  %w{intnet2 nic3 cpus memory}.each { |key| puts %{#{key}="#{vm.fetch(key)}"} if vm.key?(key) }
  puts %{macaddress2="080027A1B2C3"}
  if vm["nic2"] == "nat" && vm["forwarding2"]
    puts %{Forwarding(0)="#{vm["forwarding2"]},tcp,,8081,,80"}
  end
  puts %{SharedFolderNameMachineMapping1="#{vm.fetch("share")}"} if vm.key?("share")
  Array(vm["managed_shares"]).each_with_index { |name, index| puts %{SharedFolderNameMachineMapping#{index + 2}="#{name}"} }
when "clonevm"
  abort "attempted to clone a running source" unless registry.fetch(uuid).fetch("state") == "poweroff"
  abort "expected a full registered clone" unless options.include?("--register") && !options.include?("--options") &&
    options.each_cons(2).include?(%w{--mode machine})

  clone_uuid = options.fetch(options.index("--uuid") + 1)
  abort "clone already registered" if registry.key?(clone_uuid)

  if File.exist?(File.join(File.dirname(registry_path), "fail_before_registration"))
    directory = options.fetch(options.index("--basefolder") + 1)
    File.write(File.join(directory, "unverified.vdi"), "unverified media")
    abort "simulated pre-registration failure"
  end

  name = options.fetch(options.index("--name") + 1)
  registry[clone_uuid] = registry.fetch(uuid).merge("name" => name, "source" => uuid)
  File.write(registry_path, JSON.generate(registry))
  failure_marker = File.join(File.dirname(registry_path), "fail_clone_once")
  if File.exist?(failure_marker)
    File.delete(failure_marker)
    abort "simulated clone failure"
  end
when "modifyvm"
  vm = registry.fetch(uuid)
  abort "VM must be stopped" unless vm.fetch("state") == "poweroff"

  %w{nic2 nic3 intnet2 cpus memory}.each do |key|
    index = options.index("--#{key}")
    vm[key] = options.fetch(index + 1) if index
  end
  if vm["source"] && options.include?("--vrde")
    expected = { "--vrde" => "off", "--clipboard-mode" => "disabled", "--drag-and-drop" => "disabled",
                 "--usb-ohci" => "off", "--usb-ehci" => "off", "--usb-xhci" => "off",
                 "--nic1" => "nat", "--cable-connected1" => "on" }
    abort "missing clone isolation options" unless expected.all? { |key, value| options.each_cons(2).include?([key, value]) }
    vm["cable1"] = "on"
  end
  options.each_index do |index|
    next unless options[index] == "--nat-pf1"

    rule = options.fetch(index + 1)
    forwards = vm["forwards"] ||= []
    if rule == "delete"
      name = options.fetch(index + 2)
      if vm["forwarding1"] == name
        vm.delete("forwarding1")
      else
        abort "forwarding rule belongs to another adapter" unless forwards.reject! { |existing| existing.split(",").first == name }
      end
    else
      abort "expected loopback forwarding" unless /\Akitchen-(ssh|forward),tcp,127[.]0[.]0[.]1,/.match?(rule)

      forwards << rule
    end
  end
when "sharedfolder"
  id, name = options
  abort "missing shared folder name" unless name.start_with?("--name=")

  share = name.delete_prefix("--name=")
  vm = registry.fetch(id)
  case target
  when "add"
    (vm["managed_shares"] ||= []) << share
  when "remove"
    if vm["share"] == share
      vm.delete("share")
    else
      abort "unknown shared folder" unless vm.fetch("managed_shares", []).delete(share)
    end
  else
    abort "unexpected shared folder operation"
  end
when "startvm"
  abort "clone network cable disconnected" if registry.fetch(uuid)["cable1"] == "off"
  registry.fetch(uuid)["state"] = "running"
when "controlvm"
  registry.fetch(uuid)["state"] = "poweroff"
when "snapshot"
  abort "unexpected snapshot operation" unless uuid && options == %w{list --machinereadable}

  puts "This machine does not have any snapshots"
when "unregistervm"
  registry.delete(uuid)
else
  abort "unexpected VBoxManage command #{ARGV.inspect}"
end

File.write(registry_path, JSON.generate(registry))
