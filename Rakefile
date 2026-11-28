require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.test_files = FileList["{spec/**/*_spec,test/**/*_test}.rb"].exclude("test/network_test.rb")
end

task :test do
  ruby "test/network_test.rb"
  ruby "-Ilib", "-e", %q{require "kitchen/driver/virtualbox"}
end
