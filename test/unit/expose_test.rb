# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class ExposeTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    @app = File.join(@dir, "app")
    @gem = File.join(@dir, "gem")
    write(@app, "js/app.js", %(import {b} from "@lib/b.js"\nimport {x} from "@other/x.js"\n))
    write(@gem, "a.js", "export const a = 1\n")
    write(@gem, "b.js", %(import {a} from "./a.js"\nexport const b = a\n))
    @handler = Assiette::AssetHandler.new(root: @app).expose("@lib", @gem)
  end

  teardown { FileUtils.rm_rf(@dir) }

  def write(root, path, content)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), content)
  end

  def served(url_path) = @handler.dependency_graph.rewrite_content(url_path, File.read(@handler.resolve_file(url_path)))

  test "an exposed directory is served under its handle" do
    assert_equal File.join(@gem, "b.js"), @handler.resolve_file("/@lib/b.js").to_s
    assert_match %r{\A/@lib/b\.js\?s=[0-9a-f]{8}\z}, @handler.absolute_asset_url_path("/@lib/b.js")
  end

  test "an import by handle becomes the URL the file is served at, fingerprinted" do
    tag = @handler.dependency_graph.tree_sha("@lib/b.js")
    assert_includes served("js/app.js"), %(from "../@lib/b.js?s=#{tag}")
    assert_includes served("@lib/b.js"), %(from "./a.js?s=#{@handler.dependency_graph.tree_sha("@lib/a.js")}")
  end

  test "a handle nothing was exposed under is left for an import map" do
    assert_includes served("js/app.js"), %(from "@other/x.js")
  end

  test "editing an exposed file moves the fingerprint of the app module that imports it" do
    before = @handler.dependency_graph.tree_sha("js/app.js")
    sleep 0.01
    write(@gem, "a.js", "export const a = 2\n")
    File.utime(Time.now + 5, Time.now + 5, File.join(@gem, "a.js"))
    refute_equal before, @handler.dependency_graph.tree_sha("js/app.js")
  end

  test "several directories under one handle are searched in order" do
    theme = File.join(@dir, "theme")
    write(theme, "a.js", "export const a = 'theme'\n")
    write(theme, "c.js", "export const c = 3\n")
    handler = Assiette::AssetHandler.new(root: @app).expose("@lib", [theme, @gem])
    assert_equal File.join(theme, "a.js"), handler.resolve_file("@lib/a.js").to_s
    assert_equal File.join(@gem, "b.js"), handler.resolve_file("@lib/b.js").to_s
    assert_equal File.join(theme, "c.js"), handler.resolve_file("@lib/c.js").to_s
  end

  test "the app's own file under the handle wins" do
    write(@app, "@lib/a.js", "export const a = 'app'\n")
    assert_equal File.join(@app, "@lib/a.js"), @handler.resolve_file("@lib/a.js").to_s
  end

  test "a handle has to look like one" do
    assert_raises(ArgumentError) { @handler.expose("lib", @dir) }
    assert_raises(ArgumentError) { @handler.expose("@", @dir) }
  end

  test "exposing a handle again with the same directory changes nothing, and says nothing" do
    _, err = capture_io { @handler.expose("@lib", @gem) }
    assert_empty err
    assert_equal({"@lib" => [Pathname.new(@gem)]}, @handler.exposed)
    assert_equal File.join(@gem, "a.js"), @handler.resolve_file("@lib/a.js").to_s
  end

  test "exposing a handle again from elsewhere replaces it, with a warning" do
    other = File.join(@dir, "other")
    write(other, "a.js", "export const a = 'other'\n")
    _, err = capture_io { @handler.expose("@lib", other) }
    assert_match(/@lib was exposed from .*gem, and now from .*other instead/, err)
    assert_equal({"@lib" => [Pathname.new(other)]}, @handler.exposed)
    assert_equal File.join(other, "a.js"), @handler.resolve_file("@lib/a.js").to_s
    assert_nil @handler.resolve_file("@lib/b.js"), "the old directory is gone, not searched second"
  end

  test "modules of an exposed directory are not listed for preloading" do
    assert_equal ["/js/app.js"], @handler.js_modules.map { |mod| mod[:path] }
  end

  test "modules of exposed directories are listed for preloading when asked for" do
    other = File.join(@dir, "other")
    write(other, "x.js", "export const x = 1\n")
    @handler.expose("@other", other)

    everything = ["/@lib/a.js", "/@lib/b.js", "/@other/x.js", "/js/app.js"]
    assert_equal everything, @handler.js_modules(exposed: :all).map { |mod| mod[:path] }
    assert_equal everything, @handler.js_modules(exposed: true).map { |mod| mod[:path] }
    assert_equal ["/@lib/a.js", "/@lib/b.js", "/js/app.js"], @handler.js_modules(exposed: "@lib").map { |mod| mod[:path] }
    assert_equal everything, @handler.js_modules(exposed: ["@lib", "@other"]).map { |mod| mod[:path] }
    assert_equal ["/js/app.js"], @handler.js_modules(exposed: "@nothing").map { |mod| mod[:path] }
    assert_match(/\Asha256-/, @handler.js_modules(exposed: "@lib").first[:integrity])
  end

  test "a Rails app has a place for gems to expose their directories" do
    assert_kind_of Hash, Rails.application.config.assiette.exposed
  end
end
