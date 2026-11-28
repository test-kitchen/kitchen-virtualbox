require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.test_files = FileList["spec/**/*_spec.rb", "test/**/*_test.rb", "test/snapshot_restore.rb"].exclude("test/network_test.rb", "test/winrm_test.rb")
end

task :test do
  ruby "-Ilib", "-e", %q{require "kitchen/driver/virtualbox"}
  ruby "test/network_test.rb"
  ruby "test/winrm_test.rb", "negotiate", "http", "5985"
  ruby "test/winrm_test.rb", "ssl", "https", "5986"
  ruby "test/winrm_test.rb", "negotiate", "http", "15985", "15985"
  ruby "test/winrm_test.rb", "ssh", "ssh", "22"
end
