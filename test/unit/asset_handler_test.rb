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

  test "absolute_asset_url_path returns versioned URL for existing file" do
    result = @handler.absolute_asset_url_path("/application.css")
    assert result
    assert_match %r{\Aapplication\.css\?v=}, result.sub(%r{\A/}, "")
  end

  test "absolute_asset_url_path returns nil for missing file" do
    assert_nil @handler.absolute_asset_url_path("/nonexistent.css")
  end

  test "absolute_asset_url_path prepends script_name" do
    result = @handler.absolute_asset_url_path("/application.css", "/myapp")
    assert result.start_with?("/myapp/")
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
end
