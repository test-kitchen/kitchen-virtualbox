desc "Verify Test Kitchen can load and exercise the Virtualbox driver"
task :test do
  ruby "-Ilib", "-e", 'require "kitchen/driver/virtualbox"'
  ruby "test/registered_source_test.rb"
end
