# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "minitest/autorun"
require "minitest/mock"
require "kitchen/driver/virtualbox"

describe Kitchen::Driver::Virtualbox do
  let(:driver) { Kitchen::Driver::Virtualbox.new(kitchen_root: Dir.pwd) }

  it "reports an uncreated VM without calling the provider" do
    driver.stub(:command, ->(*) { flunk "unexpected provider call" }) do
      result = driver.status({})

      _(result.values_at(:live, :state, :source)).must_equal [false, "not_created", "driver"]
    end
  end

  it "uses the saved name to discover the VM even before its ID is saved" do
    command = ->(*arguments) do
      case arguments
      when %w{VBoxManage list vms} then %Q{"kitchen-test" {1234-abcd}\n}
      when ["VBoxManage", "showvminfo", "1234-abcd", "--machinereadable"] then %Q{VMState="running"\n}
      else flunk "unexpected provider call: #{arguments.inspect}"
      end
    end
    driver.stub(:command, command) do
      result = driver.status(virtualbox_name: "kitchen-test")

      _(result.values_at(:live, :state, :resource_id)).must_equal [true, "running", "1234-abcd"]
      _(Time.iso8601(result[:checked_at])).must_be_instance_of Time
    end
  end

  it "distinguishes a missing VM from an unavailable provider" do
    state = { virtualbox_uuid: "1234-abcd" }
    driver.stub(:command, "") do
      _(driver.status(state).values_at(:live, :state)).must_equal [false, "not_created"]
    end
    driver.stub(:command, ->(*) { raise Kitchen::ActionFailed, "host unavailable" }) do
      _(driver.status(state).values_at(:live, :state, :message)).must_equal [nil, "unknown", "host unavailable"]
    end
  end

  it "reports host and source problems without modifying a VM" do
    problems = []
    driver = Kitchen::Driver::Virtualbox.new(kitchen_root: Dir.pwd, box: "missing.box")
    driver.stub(:command, ->(*) { raise Kitchen::ActionFailed, "host unavailable" }) do
      driver.stub(:warn, ->(message) { problems << message }) do
        _(driver.doctor({})).must_equal true
      end
    end

    _(problems.first).must_equal "host unavailable"
    _(problems.last).must_match(/missing\.box/)
  end

  it "accepts a readable local box and an available provider" do
    Dir.mktmpdir do |root|
      path = File.join(root, "local.box")
      File.write(path, "")
      driver = Kitchen::Driver::Virtualbox.new(kitchen_root: root, box: "local.box")

      driver.stub(:command, "") do
        _(driver.doctor({})).must_equal false
      end
    end
  end

end
