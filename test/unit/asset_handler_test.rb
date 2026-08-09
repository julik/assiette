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

  # --- apex digest ---

  test "digest returns a 16-char hex hash" do
    assert_match(/\A[0-9a-f]{16}\z/, @handler.digest)
  end

  test "digest is stable across repeated calls" do
    assert_equal @handler.digest, @handler.digest
  end

  test "interior assets are absent from apex_paths but still move the digest" do
    with_tmpdir_handler do |handler, _dir|
      before = handler.digest
      apexes = handler.dependency_graph.apex_paths

      assert_includes apexes, "js/root_a.js"
      assert_not_includes apexes, "js/mid/alpha.js"
      assert_not_includes apexes, "js/leaf/alpha_one.js"

      edit_in_place handler.resolve_file("js/leaf/alpha_one.js")

      assert_not_equal before, handler.digest,
        "editing an interior asset must move the apex digest"
    end
  end

  test "a cold handler and one that has already served an asset agree" do
    warm = build_handler
    warm.absolute_asset_url_path("/js/root_a.js")

    assert_equal ["js/root_a.js"], warm.dependency_graph.apex_paths,
      "lazily populated graph should only know about what was asked for"

    assert_equal build_handler.digest, warm.digest
  end

  test "a cycle nothing points into still contributes to the digest" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "entry.js"), "export const x = 1\n")
      File.write(File.join(dir, "cycle_a.js"), <<~JS)
        import {b} from "./cycle_b.js"
        export function a() { return "a" + b() }
      JS
      File.write(File.join(dir, "cycle_b.js"), <<~JS)
        import {a} from "./cycle_a.js"
        export function b() { return "b" + a() }
      JS
      handler = Assiette::AssetHandler.new(root: dir)

      before = handler.digest
      apexes = handler.dependency_graph.apex_paths
      assert_includes apexes, "cycle_a.js", "an unreferenced cycle must be adopted"
      assert_includes apexes, "cycle_b.js"

      edit_in_place File.join(dir, "cycle_a.js")

      assert_not_equal before, handler.digest
    end
  end

  test "adding a file moves the digest" do
    with_tmpdir_handler do |handler, dir|
      before = handler.digest
      File.write(File.join(dir, "js", "root_c.js"), "export const c = 1\n")

      assert_not_equal before, handler.digest
    end
  end

  test "removing a file moves the digest" do
    with_tmpdir_handler do |handler, dir|
      before = handler.digest
      File.unlink(File.join(dir, "js", "root_b.js"))

      after = handler.digest
      assert_not_equal before, after
      assert_equal after, handler.digest, "digest must settle after a deletion"
      assert_not_includes handler.dependency_graph.apex_paths, "js/root_b.js"
    end
  end

  test "renaming a file moves the digest even though no content changed" do
    with_tmpdir_handler do |handler, dir|
      before = handler.digest
      File.rename(File.join(dir, "js", "root_b.js"), File.join(dir, "js", "root_c.js"))

      assert_not_equal before, handler.digest,
        "the url_path is part of the digest, so a pure rename must move it"
    end
  end

  test "digest picks up an in-place edit without re-walking the directories" do
    with_tmpdir_handler do |handler, _dir|
      walks = 0
      handler.define_singleton_method(:each_mapped_file) do |&block|
        walks += 1
        super(&block)
      end

      before = handler.digest
      assert_equal 1, walks

      edit_in_place handler.resolve_file("js/leaf/alpha_one.js")

      assert_not_equal before, handler.digest
      assert_equal 1, walks,
        "an in-place edit leaves directory mtimes alone and must not re-walk"
    end
  end

  private

  def build_handler
    Assiette::AssetHandler.new(
      root: File.expand_path("../../dummy/app/assets", __FILE__),
      additional_directory_mappings: {"/" => File.expand_path("../../dummy/public", __FILE__)}
    )
  end

  # Creates a tmpdir with a copy of the JS fixtures for mutation-safe tests.
  def with_tmpdir_handler
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.expand_path("../../dummy/app/assets/js", __FILE__), File.join(dir, "js"))
      yield Assiette::AssetHandler.new(root: dir), dir
    end
  end

  # Appends to a file without disturbing the mtime of the directory holding it.
  def edit_in_place(abs)
    File.write(abs, File.read(abs) + "\n// edited")
    FileUtils.touch(abs, mtime: Time.now + 1)
  end
end
