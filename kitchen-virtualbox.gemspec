# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require_relative "lib/kitchen/driver/virtualbox_version"

Gem::Specification.new do |gem|
  gem.name = "kitchen-virtualbox"
  gem.version = Kitchen::Driver::VIRTUALBOX_VERSION
  gem.authors = ["Dan Webb"]
  gem.email = ["dan.webb@damacus.io"]
  gem.summary = "Test Kitchen driver for Oracle VirtualBox"
  gem.license = "Apache-2.0"
  gem.homepage = "https://kitchen.ci/"
  gem.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "README.md", "LICENSE"] }
  gem.require_paths = ["lib"]
  gem.required_ruby_version = ">= 3.1"
  gem.add_dependency "mixlib-shellout", ">= 3.0", "< 4.0"
  gem.add_dependency "test-kitchen", "~> 4.2"
  gem.add_development_dependency "minitest", "~> 5.0"
end
