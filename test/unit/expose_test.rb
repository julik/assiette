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

  def paths(modules) = modules.map { |mod| mod[:path] }

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

  test "exposed modules are preloaded when the app's modules reach them, by import or by a literal import()" do
    other = File.join(@dir, "other")
    write(other, "x.js", %(import {c} from "@lib/c.js"\nexport const x = c\n)) # reaches across handles
    write(other, "y.js", "export const y = 2\n")
    write(@gem, "c.js", "export const c = 3\n")
    write(@gem, "d.js", "export const d = 4\n")
    write(@gem, "e.js", "export const e = 5\n")
    write(@app, "js/app.js", <<~JS)
      import {b} from "@lib/b.js"
      import {x} from "@other/x.js"
      const d = await import("@lib/d.js")
      const e = await import(`@lib/${name}.js`)
    JS
    @handler.expose("@other", other)

    reached = ["/@lib/a.js", "/@lib/b.js", "/@lib/c.js", "/@lib/d.js", "/@other/x.js", "/js/app.js"]
    assert_equal reached, paths(@handler.js_modules), "a, c and d are reached only through b, x and import()"
    assert_equal reached, paths(@handler.js_modules(exposed: :imported))
    assert_equal (reached + ["/@lib/e.js"]).sort, paths(@handler.js_modules(exposed: "@lib")), "the whole of @lib for the computed import, and what is reached in @other"
    assert_equal (reached + ["/@lib/e.js", "/@other/y.js"]).sort, paths(@handler.js_modules(exposed: :all))
    assert_equal (reached + ["/@lib/e.js", "/@other/y.js"]).sort, paths(@handler.js_modules(exposed: ["@lib", "@other"]))
    assert_equal ["/js/app.js"], paths(@handler.js_modules(exposed: []))
    assert_equal ["/js/app.js"], paths(@handler.js_modules(exposed: :none))
    assert_equal reached, paths(@handler.js_modules(exposed: "@nothing")), "an unknown handle lists nothing extra"
    @handler.js_modules.each { |mod| assert_match(/\Asha256-/, mod[:integrity], mod[:path]) }
  end

  test "an exposed module nothing imports is served but not preloaded" do
    write(@gem, "orphan.js", "export const o = 1\n")
    assert_equal File.join(@gem, "orphan.js"), @handler.resolve_file("/@lib/orphan.js").to_s
    assert_equal ["/@lib/a.js", "/@lib/b.js", "/js/app.js"], paths(@handler.js_modules)
  end

  test "the app's own copy under the handle is listed once" do
    write(@app, "@lib/b.js", "export const b = 'mine'\n")
    assert_equal ["/@lib/b.js", "/js/app.js"], paths(@handler.js_modules)
    assert_equal File.join(@app, "@lib/b.js"), @handler.resolve_file("/@lib/b.js").to_s
  end

  test "a Server announces its handler to the gems that hook on_load(:assiette)" do
    # Hooks stay registered for the rest of the run, so they point at a directory that does too
    gem = File.expand_path("../dummy/vendor/counter_gem", __dir__)
    ActiveSupport.on_load(:assiette) { expose "@hooked", gem }
    handler = Assiette::AssetHandler.new(root: @app)
    Assiette::Server.new(->(_env) { [404, {}, []] }, handler)
    assert_equal [Pathname.new(gem)], handler.exposed["@hooked"]

    later = Assiette::AssetHandler.new(root: @app)
    Assiette::Server.new(->(_env) { [404, {}, []] }, later)
    ActiveSupport.on_load(:assiette) { expose "@late", gem }
    assert_equal [Pathname.new(gem)], later.exposed["@late"], "a hook registered after the Server was built still runs"

    per_request = Assiette::AssetHandler.new(root: @app)
    Assiette::Server.new(->(_env) { [404, {}, []] }, ->(_env) { per_request })
    assert_empty per_request.exposed, "a handler made per request is not announced"
  end
end
