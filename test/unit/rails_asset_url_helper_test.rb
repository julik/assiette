# frozen_string_literal: true

require "test_helper"

class RailsAssetUrlHelperTest < ActiveSupport::TestCase
  setup do
    @handler = Assiette::AssetHandler.new(
      root: File.expand_path("../../dummy/app/assets", __FILE__),
      additional_directory_mappings: {"/" => File.expand_path("../../dummy/public", __FILE__)}
    )
    @original_assets = Rails.application.assets
  end

  teardown do
    Rails.application.assets = @original_assets
  end

  test "compute_asset_path resolves known asset through handler" do
    Rails.application.assets = @handler
    helper = build_helper
    result = helper.compute_asset_path("application.css", {})
    assert_match %r{application\.css\?v=}, result
  end

  test "compute_asset_path falls back to super for unknown asset" do
    Rails.application.assets = @handler
    helper = build_helper
    result = helper.compute_asset_path("unknown.woff2", type: :font)
    assert_includes result, "unknown.woff2"
    refute_includes result, "?v="
  end

  test "compute_asset_path falls back when no handler is configured" do
    Rails.application.assets = nil
    helper = build_helper
    result = helper.compute_asset_path("application.css", {})
    assert_includes result, "application.css"
    refute_includes result, "?v="
  end

  private

  def build_helper
    klass = Class.new do
      include ActionView::Helpers::AssetUrlHelper
      include Assiette::RailsAssetUrlHelper

      def config
        Struct.new(:asset_host, :assets_dir, :relative_url_root, :action_controller)
          .new(nil, "public", nil, nil)
      end
    end

    klass.new
  end
end
