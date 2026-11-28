# Copyright 2026 Dan Webb
# SPDX-License-Identifier: Apache-2.0

require "digest"
require "fileutils"
require "json"
require "kitchen/box/catalog"
require "minitest/autorun"
require "open3"
require "socket"
require "tmpdir"
require "yaml"

class RemoteBoxTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @catalog = File.join(@root, "catalog")
    @cache = File.join(@root, "cache")
    @temporary = File.join(@root, "temporary")
    @import = File.join(@root, "import")
    FileUtils.mkdir_p([@catalog, @temporary])
    @vboxmanage = File.join(@root, "VBoxManage")
    File.write(@vboxmanage, <<~RUBY)
      #!#{RbConfig.ruby}
      if ARGV.first == "import"
        File.write(#{@import.inspect}, File.read(ARGV.fetch(1)))
        abort "fixture reached VirtualBox import"
      end
      abort "unexpected VBoxManage command" unless ARGV == %w{list vms}
    RUBY
    File.chmod(0o700, @vboxmanage)

    @requests = Queue.new
    @first = archive("one.box", "version one")
    @second = archive("two.box", "version two")
  end

  def teardown
    @worker&.kill&.join
  ensure
    @server&.close
    FileUtils.remove_entry_secure(@root)
  end

  def test_selects_exact_version_and_reuses_verified_cache_without_http
    require_remote_catalog
    serve("/boxes/one.box" => @first, "/boxes/two%20release.box" => @second)
    configure(version: "1.0")
    assert_import("version one")
    assert_equal "/boxes/one.box", @requests.pop(true)
    assert_empty Dir.children(@temporary)
    destroy
    assert_import("version one")
    assert @requests.empty?

    configure(version: "2.0")
    output, status = kitchen("create")
    refute status.success?, output
    assert_match(/Run kitchen destroy before changing the cached box/, output)
    assert @requests.empty?
    destroy

    assert_import("version two")
    assert_equal "/boxes/two%20release.box", @requests.pop(true)
    assert @requests.empty?
    destroy
  end

  def test_truncated_response_leaves_no_archive_or_temporary_file
    require_remote_catalog
    serve("/boxes/one.box" => @first.byteslice(0, 16))
    configure(version: "1.0")
    output, status = kitchen("create")
    refute status.success?, output
    assert_match(/Size mismatch while downloading remote box/, output)
    refute_path_exists @import
    assert_empty Dir.glob(File.join(@cache, "*", "{archive.box,download-*}"))
    assert_empty Dir.children(@temporary)
    destroy
  end

  def test_rejects_same_size_corrupt_download_and_retries_cleanly
    require_remote_catalog
    corrupt = @first.dup
    corrupt.setbyte(0, corrupt.getbyte(0) ^ 1)
    serve("/boxes/one.box" => corrupt)
    configure(version: "1.0")
    output, status = kitchen("create")
    refute status.success?, output
    assert_match(/SHA-256.*mismatch/, output)
    refute_path_exists @import
    assert_empty Dir.glob(File.join(@cache, "*", "{archive.box,download-*}"))
    assert_empty Dir.children(@temporary)
    assert_equal "/boxes/one.box", @requests.pop(true)

    @worker.kill.join
    serve("/boxes/one.box" => @first)
    assert_import("version one")
    assert_equal "/boxes/one.box", @requests.pop(true)
    destroy
  end

  def test_local_paths_and_catalogs_work_without_remote_configuration
    File.binwrite(File.join(@catalog, "one.box"), @first)
    configure(version: "1.0", remote: false)
    assert_import("version one")
    destroy
    configure(local: "catalog/one.box", remote: false)
    assert_import("version one")
    destroy
  end

  private

  def require_remote_catalog
    return if Kitchen::Box::Catalog.method_defined?(:copy_archive)

    skip "Remote catalogs require Test Kitchen with URL support (set TEST_KITCHEN_PATH to a compatible checkout)"
  end

  def write_manifest(remote)
    first = record("1.0", "one.box", @first, remote)
    second = record("2.0", remote ? "two%20release.box" : "two.box", @second, remote)
    wrong_provider = record("1.0", "wrong-provider.box", @second, remote).merge("provider" => "parallels")
    wrong_arch = record("1.0", "wrong-architecture.box", @second, remote).merge("architecture" => "other")
    File.write(File.join(@catalog, "manifest.json"), JSON.generate([wrong_provider, wrong_arch, second, first]))
  end

  def archive(filename, content)
    Dir.mktmpdir("archive-", @root) do |staging|
      File.write(File.join(staging, "box.ovf"), content)
      File.write(File.join(staging, "metadata.json"), '{"provider":"virtualbox"}')
      path = File.join(staging, filename)
      system("/usr/bin/tar", "-cf", path, "-C", staging, "box.ovf", "metadata.json", exception: true)
      File.binread(path)
    end
  end

  def record(version, filename, archive, remote)
    location = remote ? { "url" => "#{@base_url}/#{filename}" } : { "file" => filename }
    { "name" => "fixture/guest", "version" => version, "provider" => "virtualbox",
      "architecture" => Kitchen::Box::Catalog.host_architecture,
      "bytes" => archive.bytesize, "sha256" => Digest::SHA256.hexdigest(archive) }.merge(location)
  end

  def serve(archives)
    unless @server
      @server = TCPServer.new("127.0.0.1", 0)
      @base_url = "http://127.0.0.1:#{@server.local_address.ip_port}/boxes"
    end
    @worker = Thread.new do
      loop do
        client = @server.accept
        begin
          path = client.gets.split.fetch(1)
          loop do
            break if [nil, "\r\n"].include?(client.gets)
          end
          @requests << path
          body = archives.fetch(path)
          client.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n", body)
        ensure
          client.close
        end
      end
    end
  end

  def configure(version: nil, local: nil, remote: true)
    driver = {
      "name" => "virtualbox", "vboxmanage" => @vboxmanage,
      "box" => local || { "name" => "fixture/guest", "version" => version },
      "box_manifest" => File.join(@catalog, "manifest.json"), "box_cache" => @cache
    }
    write_manifest(remote)
    project = {
      "driver" => driver, "transport" => { "name" => "dummy" }, "provisioner" => { "name" => "dummy" },
      "platforms" => [{ "name" => "virtualbox" }], "suites" => [{ "name" => "default" }]
    }
    File.write(File.join(@root, "kitchen.yml"), YAML.dump(project))
  end

  def kitchen(action)
    Open3.capture2e({ "TMPDIR" => @temporary }, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__),
      Gem.bin_path("test-kitchen", "kitchen"), action, "default-virtualbox", "-l", "debug", chdir: @root)
  end

  def assert_import(content)
    FileUtils.rm_f(@import)
    output, status = kitchen("create")
    refute status.success?, output
    assert_match(/fixture reached VirtualBox import/, output)
    assert_equal content, File.read(@import)
  end

  def destroy
    output, status = kitchen("destroy")
    assert status.success?, output
    assert_empty Dir.glob(File.join(@cache, "*", "leases", "*"))
  end
end
