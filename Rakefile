desc "Run the VirtualBox driver tests"
task :test do
  ruby "-Ilib", "-e", 'require "kitchen/driver/virtualbox"'
  ruby "test/shared_folders_test.rb"
end
