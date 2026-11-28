source "https://rubygems.org"

if ENV["TEST_KITCHEN_PATH"]
  gem "test-kitchen", path: ENV.fetch("TEST_KITCHEN_PATH")
end

gemspec development_group: :test

gem "minitest", "~> 6.0"
gem "rake"

group :cookstyle do
  gem "cookstyle"
end

group :smoke do
  gem "kitchen-ansible", "~> 0.58.0"
  gem "kitchen-cinc", "~> 1.1.0"
  gem "kitchen-puppet", "~> 3.7.0"
  gem "mixlib-install", "4.1.0", source: "https://rubygems.cinc.sh"
end
