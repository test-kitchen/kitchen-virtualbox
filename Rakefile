desc "Verify the VirtualBox driver through Test Kitchen"
task :test do
  ruby "-Ilib", "-e", 'require "kitchen/driver/virtualbox"'
  ruby "test/winrm_test.rb", "negotiate", "http", "5985"
  ruby "test/winrm_test.rb", "ssl", "https", "5986"
end
