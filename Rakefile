require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.test_files = FileList["spec/**/*_spec.rb", "test/shared_folders_test.rb"]
end

task :test do
  ruby "-Ilib", "-e", %q{require "kitchen/driver/virtualbox"}
  ruby "test/network_test.rb"
end
