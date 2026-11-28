require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.pattern = "spec/**/*_spec.rb"
end

task :test do
  ruby "-Ilib", "-e", %q{require "kitchen/driver/virtualbox"}
  ruby "test/network_test.rb"
  ruby "test/remote_box_test.rb"
end
