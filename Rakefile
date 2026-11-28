desc "Run the VirtualBox driver tests"
task :test do
  ruby "-Ilib", "-e", 'require "kitchen/driver/virtualbox"'
  ruby "test/snapshot_restore.rb"
end
