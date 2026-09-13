# frozen_string_literal: true

require "test_helper"

class HelpersTest < ActiveSupport::TestCase
  setup do
    @assets = Assiette::AssetHandler.new(root: File.expand_path("../dummy/app/assets", __dir__))
    @public = Assiette::AssetHandler.new(root: File.expand_path("../dummy/public", __dir__))
  end

  test "assiette_asset_path resolves through the only handler in the stack" do
    helper = build_helper([entry(@assets)])

    assert_match %r{\A/application\.css\?s=[0-9a-f]{8}\z}, helper.assiette_asset_path("/application.css")
  end

  test "assiette_asset_path prepends the entry's script_name" do
    helper = build_helper([entry(@assets, "/mounted")])

    assert_match %r{\A/mounted/application\.css\?s=}, helper.assiette_asset_path("/application.css")
  end

  test "assiette_asset_path resolves an asset held by the innermost handler" do
    helper = build_helper([entry(@public), entry(@assets)])

    assert_match %r{\A/application\.css\?s=}, helper.assiette_asset_path("/application.css")
  end

  test "assiette_asset_path resolves an asset held by an outer handler" do
    helper = build_helper([entry(@public), entry(@assets)])

    assert_match %r{\A/logo\.png\?s=}, helper.assiette_asset_path("/logo.png"),
      "the innermost handler does not hold every asset a page links"
  end

  test "assiette_asset_path prefers the innermost handler when both hold the path" do
    with_two_roots do |outer, inner|
      helper = build_helper([entry(outer, "/outer"), entry(inner, "/inner")])

      assert_match %r{\A/inner/shared\.css\?s=}, helper.assiette_asset_path("/shared.css")
    end
  end

  test "assiette_asset_path returns nil when no handler in the stack has the file" do
    helper = build_helper([entry(@public), entry(@assets)])

    assert_nil helper.assiette_asset_path("/nonexistent.css")
  end

  test "assiette_asset_integrity walks the stack too" do
    helper = build_helper([entry(@public), entry(@assets)])

    assert helper.assiette_asset_integrity("/logo.png").start_with?("sha256-")
    assert helper.assiette_asset_integrity("/application.css").start_with?("sha256-")
  end

  test "assiette_asset_integrity returns nil when no handler in the stack has the file" do
    helper = build_helper([entry(@public), entry(@assets)])

    assert_nil helper.assiette_asset_integrity("/nonexistent.css")
  end

  test "assiette_stylesheet_tag renders an outer handler's stylesheet" do
    with_two_roots do |outer, inner|
      helper = build_helper([entry(outer), entry(inner)])
      # Only the outer root has outer_only.css
      tag = helper.assiette_stylesheet_tag("/outer_only.css")

      assert_match %r{href="/outer_only\.css\?s=[0-9a-f]{8}"}, tag
      assert_match %r{integrity="sha256-}, tag
    end
  end

  test "the path helpers raise when no Server ran" do
    assert_raise(RuntimeError) { build_helper(nil).assiette_asset_path("/application.css") }
    assert_raise(RuntimeError) { build_helper([]).assiette_asset_path("/application.css") }
    assert_raise(RuntimeError) { build_helper(nil).assiette_asset_integrity("/application.css") }
    assert_raise(RuntimeError) { build_helper(nil).assiette_modulepreload_tags }
  end

  test "assiette_modulepreload_tags stays scoped to the innermost handler" do
    with_two_roots do |outer, inner|
      helper = build_helper([entry(outer), entry(inner)])
      tags = helper.assiette_modulepreload_tags

      assert_includes tags, "/inner_module.js?s="
      assert_not_includes tags, "outer_module.js",
        "listing every handler's modules would leak one tenant's file list onto another's page"
    end
  end

  private

  def entry(handler, script_name = "")
    {handler: handler, script_name: script_name}
  end

  # Two disjoint asset roots which both hold a shared.css, standing in for two
  # tenants' directories mounted through two stacked Servers.
  def with_two_roots
    Dir.mktmpdir do |outer_root|
      Dir.mktmpdir do |inner_root|
        File.write(File.join(outer_root, "shared.css"), ".shared { color: red }\n")
        File.write(File.join(outer_root, "outer_only.css"), ".outer { color: green }\n")
        File.write(File.join(outer_root, "outer_module.js"), "export const outer = 1\n")
        File.write(File.join(inner_root, "shared.css"), ".shared { color: blue }\n")
        File.write(File.join(inner_root, "inner_module.js"), "export const inner = 1\n")

        yield Assiette::AssetHandler.new(root: outer_root), Assiette::AssetHandler.new(root: inner_root)
      end
    end
  end

  def build_helper(stack)
    klass = Class.new do
      include ActionView::Helpers::TagHelper
      include ActionView::Helpers::OutputSafetyHelper
      include Assiette::Helpers

      attr_reader :request

      def initialize(stack)
        env = stack.nil? ? {} : {"assiette.stack" => stack}
        @request = Struct.new(:env).new(env)
      end
    end

    klass.new(stack)
  end
end
