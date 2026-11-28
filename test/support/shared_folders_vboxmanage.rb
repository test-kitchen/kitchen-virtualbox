# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "json"

registry_path = ENV.fetch("VBOX_TEST_REGISTRY")
uuid = "11111111-1111-4111-8111-111111111111"
command, target, *options = ARGV
vm = JSON.parse(File.read(registry_path)) if File.exist?(registry_path)

case command
when "list"
  puts %("#{vm.fetch("name")}" {#{uuid}}) if vm
when "import"
  abort "VM already registered" if vm

  vm = { "name" => options.fetch(options.index("--vmname") + 1), "shares" => {}, "state" => "poweroff" }
when "showvminfo"
  puts %{VMState="#{vm.fetch("state")}"}
  vm.fetch("shares").each_key.with_index(1) do |name, index|
    puts %{SharedFolderNameMachineMapping#{index}="#{name}"}
  end
  puts %{Forwarding(0)="#{vm.fetch("forwarding")}"} if vm.key?("forwarding")
when "sharedfolder"
  abort "share changed outside the powered-off VM" unless options.shift == uuid && vm.fetch("state") == "poweroff"

  name = options.find { |option| option.start_with?("--name=") }.delete_prefix("--name=")
  shares = vm.fetch("shares")
  case target
  when "add"
    abort "share already exists" if shares.key?(name)

    shares[name] = options
  when "remove"
    shares.delete(name) || abort("share does not exist")
  else
    abort "unexpected sharedfolder action #{target}"
  end
when "modifyvm"
  rule = options.last
  vm["forwarding"] = rule unless rule.start_with?("delete=")
when "startvm"
  marker = File.join(File.dirname(registry_path), "fail-start-once")
  if File.exist?(marker)
    File.delete(marker)
    abort "simulated start failure"
  end
  vm["state"] = "running"
when "controlvm"
  vm["state"] = "poweroff"
when "unregistervm"
  File.delete(registry_path)
  vm = nil
else
  abort "unexpected VBoxManage command #{ARGV.inspect}"
end

File.write(registry_path, JSON.generate(vm)) if vm
