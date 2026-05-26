# frozen_string_literal: true

require "test_helper"

class AssetHandlerTest < ActiveSupport::TestCase
  setup do
    @handler = Assiette::AssetHandler.new(
      root: File.expand_path("../../dummy/app/assets", __FILE__),
      additional_directory_mappings: {"/" => File.expand_path("../../dummy/public", __FILE__)}
    )
  end

  test "resolve_file returns path for existing file" do
    result = @handler.resolve_file("application.css")
    assert result
    assert result.to_s.end_with?("application.css")
  end

  test "resolve_file returns nil for non-existent file" do
    assert_nil @handler.resolve_file("nope.css")
  end

  test "resolve_file prevents path traversal" do
    assert_nil @handler.resolve_file("../../etc/passwd")
  end

  test "absolute_asset_url_path returns versioned URL with 8-char hex hash" do
    result = @handler.absolute_asset_url_path("/application.css")
    assert result
    assert_match %r{\A/application\.css\?s=[0-9a-f]{8}\z}, result
  end

  test "absolute_asset_url_path returns nil for missing file" do
    assert_nil @handler.absolute_asset_url_path("/nonexistent.css")
  end

  test "absolute_asset_url_path prepends script_name" do
    result = @handler.absolute_asset_url_path("/application.css", "/myapp")
    assert result.start_with?("/myapp/")
    assert_match %r{\?s=[0-9a-f]{8}\z}, result
  end

  test "asset_integrity returns SRI hash for existing file" do
    result = @handler.asset_integrity("/application.css")
    assert result
    assert result.start_with?("sha256-")
  end

  test "asset_integrity returns nil for missing file" do
    assert_nil @handler.asset_integrity("/nonexistent.css")
  end

  test "js_modules returns array of modules with path and integrity" do
    modules = @handler.js_modules
    assert_kind_of Array, modules
    assert modules.any? { |m| m[:path].end_with?(".js") }
    modules.each do |mod|
      assert mod.key?(:path)
      assert mod.key?(:integrity)
    end
  end

  test "each_mapped_file yields url_path and abs_path pairs" do
    pairs = []
    @handler.each_mapped_file { |url, abs| pairs << [url, abs] }
    assert pairs.any? { |url, _| url == "application.css" }
    assert pairs.any? { |url, _| url == "js/root_a.js" }
    pairs.each do |_, abs|
      assert File.exist?(abs), "#{abs} should exist"
    end
  end

  test "dependency_graph is accessible" do
    assert_kind_of Assiette::DependencyGraph, @handler.dependency_graph
  end

  test "js_modules returns fresh integrity after a file changes" do
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.expand_path("../../dummy/app/assets/js", __FILE__), File.join(dir, "js"))
      handler = Assiette::AssetHandler.new(root: dir)

      modules_before = handler.js_modules
      mod_before = modules_before.find { |m| m[:path] == "/js/leaf/alpha_one.js" }
      assert mod_before, "alpha_one.js should be in js_modules"
      integrity_before = mod_before[:integrity]

      abs = handler.resolve_file("js/leaf/alpha_one.js")
      File.write(abs, File.read(abs) + "\n// edited")
      FileUtils.touch(abs, mtime: Time.now + 1)

      modules_after = handler.js_modules
      mod_after = modules_after.find { |m| m[:path] == "/js/leaf/alpha_one.js" }
      integrity_after = mod_after[:integrity]

      assert_not_equal integrity_before, integrity_after,
        "js_modules integrity must update when a file changes"
    end
  end
end
