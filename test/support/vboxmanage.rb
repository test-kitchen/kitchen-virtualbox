# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "json"

registry_path = ENV.fetch("VBOX_TEST_REGISTRY")
registry = JSON.parse(File.read(registry_path))
command, target, *options = ARGV
uuid = registry.key?(target) ? target : registry.find { |_, vm| vm.fetch("name") == target }&.first

case command
when "list"
  abort "unexpected list target" unless target == "vms"

  registry.each { |id, vm| puts %("#{vm.fetch("name")}" {#{id}}) }
when "showvminfo"
  vm = registry.fetch(uuid)
  puts %{UUID="#{uuid}"}
  puts %{VMState="#{vm.fetch("state")}"}
  puts 'nic1="nat"'
  puts %{nic2="#{vm.fetch("nic2", "none")}"}
  puts %{SharedFolderNameMachineMapping1="#{vm.fetch("share")}"} if vm.key?("share")
when "clonevm"
  abort "attempted to clone a running source" unless registry.fetch(uuid).fetch("state") == "poweroff"
  abort "expected a full registered clone" unless options.include?("--register") && !options.include?("--options")

  clone_uuid = options.fetch(options.index("--uuid") + 1)
  abort "clone already registered" if registry.key?(clone_uuid)

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
  index = options.index("--nic2")
  vm["nic2"] = options.fetch(index + 1) if index
when "sharedfolder"
  id, name_option, share = options
  abort "unexpected shared folder operation" unless target == "remove" && name_option == "--name"
  abort "unknown shared folder" unless registry.fetch(id).delete("share") == share
when "startvm"
  registry.fetch(uuid)["state"] = "running"
when "controlvm"
  registry.fetch(uuid)["state"] = "poweroff"
when "unregistervm"
  registry.delete(uuid)
else
  abort "unexpected VBoxManage command #{ARGV.inspect}"
end

File.write(registry_path, JSON.generate(registry))
