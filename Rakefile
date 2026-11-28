require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.pattern = "spec/**/*_spec.rb"
end

task :test do
  ruby "-Ilib", "-e", 'require "kitchen/driver/virtualbox"'
  ruby "test/winrm_test.rb", "negotiate", "http", "5985"
  ruby "test/winrm_test.rb", "ssl", "https", "5986"
  ruby "test/winrm_test.rb", "negotiate", "http", "15985", "15985"
  ruby "test/winrm_test.rb", "ssh", "ssh", "22"
end
