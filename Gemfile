source "https://rubygems.org"

if ENV["TEST_KITCHEN_PATH"]
  gem "test-kitchen", path: ENV.fetch("TEST_KITCHEN_PATH")
else
  gem "test-kitchen", github: "test-kitchen/test-kitchen", ref: "e60bb7eeed6abe214c647adbc4f10b90b1824d2c"
end

gemspec
