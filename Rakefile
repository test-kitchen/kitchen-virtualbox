desc "Verify Test Kitchen can load the VirtualBox driver and exercise its networking"
task :test do
  ruby "-Ilib", "-e", 'require "kitchen/driver/virtualbox"'
  ruby "test/network_test.rb"
end
