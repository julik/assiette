# frozen_string_literal: true

require "test_helper"

class DependencyGraphTest < ActiveSupport::TestCase
  setup do
    @handler = Assiette::AssetHandler.new(
      root: File.expand_path("../../dummy/app/assets", __FILE__),
      additional_directory_mappings: {"/" => File.expand_path("../../dummy/public", __FILE__)}
    )
    @graph = @handler.dependency_graph
  end

  # --- Asset object API ---

  test "[] returns an Asset for a known file" do
    asset = @graph["js/leaf/alpha_one.js"]
    assert_kind_of Assiette::DependencyGraph::Asset, asset
    assert_equal "js/leaf/alpha_one.js", asset.url_path
  end

  test "[] returns nil for an unknown file" do
    assert_nil @graph["nonexistent.js"]
  end

  test "Asset#checksum_tag returns 8-char hex" do
    asset = @graph["js/leaf/alpha_one.js"]
    assert_match(/\A[0-9a-f]{8}\z/, asset.checksum_tag)
  end

  test "Asset#sri_integrity returns sha256 SRI string" do
    asset = @graph["js/leaf/alpha_one.js"]
    assert_match(/\Asha256-[A-Za-z0-9+\/]+=*\z/, asset.sri_integrity)
  end

  test "Asset#checksum_tag and sri_integrity are derived from the same digest" do
    asset = @graph["js/leaf/alpha_one.js"]
    digest_bytes = Base64.strict_decode64(asset.sri_integrity.delete_prefix("sha256-"))
    assert_equal asset.checksum_tag, digest_bytes.unpack1("H8")
  end

  test "Asset#deps lists dependency url_paths" do
    asset = @graph["js/mid/alpha.js"]
    assert_includes asset.deps, "js/leaf/alpha_one.js"
    assert_includes asset.deps, "js/leaf/alpha_two.js"
  end

  test "Asset#dependents lists reverse dependency url_paths" do
    asset = @graph["js/leaf/alpha_one.js"]
    assert_includes asset.dependents, "js/mid/alpha.js"
  end

  test "leaf Asset has empty deps" do
    asset = @graph["js/leaf/alpha_one.js"]
    assert_empty asset.deps
  end

  test "standalone Asset has empty deps and dependents" do
    asset = @graph["js/root_b.js"]
    assert_empty asset.deps
    assert_empty asset.dependents
  end

  # --- tree_sha / tree_integrity convenience methods ---

  test "tree_sha returns 8-char hex string for known file" do
    assert_match(/\A[0-9a-f]{8}\z/, @graph.tree_sha("js/leaf/alpha_one.js"))
  end

  test "tree_sha returns nil for unknown file" do
    assert_nil @graph.tree_sha("nonexistent.js")
  end

  test "tree_integrity returns SRI string for known file" do
    assert_match(/\Asha256-[A-Za-z0-9+\/]+=*\z/, @graph.tree_integrity("js/leaf/alpha_one.js"))
  end

  test "tree_integrity returns nil for unknown file" do
    assert_nil @graph.tree_integrity("nonexistent.js")
  end

  # --- Hash computation across the graph ---

  test "different leaves have different hashes" do
    sha1 = @graph.tree_sha("js/leaf/alpha_one.js")
    sha2 = @graph.tree_sha("js/leaf/alpha_two.js")
    assert_not_equal sha1, sha2
  end

  test "mid-level node hash differs from its leaf's hash" do
    mid_sha = @graph.tree_sha("js/mid/alpha.js")
    leaf_sha = @graph.tree_sha("js/leaf/alpha_one.js")
    assert_not_equal mid_sha, leaf_sha
  end

  test "root node hash differs from its mid-level dep's hash" do
    root_sha = @graph.tree_sha("js/root_a.js")
    mid_sha = @graph.tree_sha("js/mid/alpha.js")
    assert_not_equal root_sha, mid_sha
  end

  test "standalone file gets raw content hash" do
    sha = @graph.tree_sha("js/root_b.js")
    abs = @handler.resolve_file("js/root_b.js")
    expected = Digest::SHA256.hexdigest(File.read(abs))[0, 8]
    assert_equal expected, sha
  end

  # --- resolve_import_for ---

  test "resolve_import_for handles relative paths" do
    assert_equal "js/leaf/alpha_one.js",
      @graph.resolve_import_for("js/mid/alpha.js", "../leaf/alpha_one.js")
  end

  test "resolve_import_for handles absolute paths" do
    assert_equal "lib/thing.js",
      @graph.resolve_import_for("js/mid/alpha.js", "/lib/thing.js")
  end

  test "resolve_import_for handles same-directory relative paths" do
    assert_equal "js/mid/sibling.js",
      @graph.resolve_import_for("js/mid/alpha.js", "./sibling.js")
  end

  # --- rewrite_content ---

  test "rewrite_content substitutes per-dep hashes in JS" do
    abs = @handler.resolve_file("js/mid/alpha.js")
    raw = File.read(abs)
    rewritten = @graph.rewrite_content("js/mid/alpha.js", raw)

    leaf1_sha = @graph.tree_sha("js/leaf/alpha_one.js")
    leaf2_sha = @graph.tree_sha("js/leaf/alpha_two.js")
    assert_includes rewritten, "../leaf/alpha_one.js?s=#{leaf1_sha}"
    assert_includes rewritten, "../leaf/alpha_two.js?s=#{leaf2_sha}"
  end

  test "rewrite_content substitutes per-dep hashes in CSS" do
    abs = @handler.resolve_file("test_with_url.css")
    raw = File.read(abs)
    rewritten = @graph.rewrite_content("test_with_url.css", raw)
    assert_match(/icon\.svg\?s=[0-9a-f]{8}/, rewritten)
  end

  test "rewrite_content returns non-JS/CSS content unchanged" do
    assert_equal "PNG binary data", @graph.rewrite_content("logo.png", "PNG binary data")
  end

  # --- invalidate! ---

  test "invalidate! forces rebuild and produces valid hashes" do
    sha_before = @graph.tree_sha("js/root_b.js")
    @graph.invalidate!
    sha_after = @graph.tree_sha("js/root_b.js")
    assert_equal sha_before, sha_after, "Same content should produce same hash after rebuild"
  end

  # --- mtime-based staleness ---

  test "mtime change triggers recomputation" do
    with_tmpdir_handler do |handler, graph|
      sha_before = graph.tree_sha("js/leaf/alpha_one.js")
      abs = handler.resolve_file("js/leaf/alpha_one.js")

      File.write(abs, File.read(abs) + "\n// changed")
      FileUtils.touch(abs, mtime: Time.now + 1)

      sha_after = graph.tree_sha("js/leaf/alpha_one.js")
      assert_not_equal sha_before, sha_after, "Hash should change when file content changes"
    end
  end

  test "ancestor propagation: changing a leaf updates mid and root" do
    with_tmpdir_handler do |handler, graph|
      root_sha_before = graph.tree_sha("js/root_a.js")
      mid_sha_before = graph.tree_sha("js/mid/alpha.js")

      abs = handler.resolve_file("js/leaf/alpha_one.js")
      File.write(abs, File.read(abs) + "\n// ancestor test")
      FileUtils.touch(abs, mtime: Time.now + 2)

      root_sha_after = graph.tree_sha("js/root_a.js")
      mid_sha_after = graph.tree_sha("js/mid/alpha.js")

      assert_not_equal mid_sha_before, mid_sha_after, "Mid-level hash should change when leaf changes"
      assert_not_equal root_sha_before, root_sha_after, "Root hash should change when leaf changes"
    end
  end

  # --- File deletion ---

  test "deleting a leaf removes it from the graph" do
    with_tmpdir_handler do |handler, graph|
      # Force build
      assert graph.tree_sha("js/leaf/alpha_one.js")

      abs = handler.resolve_file("js/leaf/alpha_one.js")
      File.delete(abs)

      assert_nil graph["js/leaf/alpha_one.js"], "Deleted file should be removed from graph"
    end
  end

  test "deleting a leaf updates ancestors' hashes" do
    with_tmpdir_handler do |handler, graph|
      mid_sha_before = graph.tree_sha("js/mid/alpha.js")

      abs = handler.resolve_file("js/leaf/alpha_one.js")
      File.delete(abs)

      mid_sha_after = graph.tree_sha("js/mid/alpha.js")
      assert_not_equal mid_sha_before, mid_sha_after,
        "Ancestor hash should change when a dependency is deleted"
    end
  end

  test "deleting a leaf propagates to root" do
    with_tmpdir_handler do |handler, graph|
      root_sha_before = graph.tree_sha("js/root_a.js")

      abs = handler.resolve_file("js/leaf/alpha_one.js")
      File.delete(abs)

      root_sha_after = graph.tree_sha("js/root_a.js")
      assert_not_equal root_sha_before, root_sha_after,
        "Root hash should change when a transitive dependency is deleted"
    end
  end

  test "deleted dep rewrites to 00000000" do
    with_tmpdir_handler do |handler, graph|
      abs_leaf = handler.resolve_file("js/leaf/alpha_one.js")
      File.delete(abs_leaf)

      abs_mid = handler.resolve_file("js/mid/alpha.js")
      raw = File.read(abs_mid)
      rewritten = graph.rewrite_content("js/mid/alpha.js", raw)
      assert_includes rewritten, "../leaf/alpha_one.js?s=00000000"
    end
  end

  # --- Cyclic imports ---

  test "cyclic imports do not raise" do
    with_cycle_handler do |_handler, graph|
      assert_nothing_raised { graph.tree_sha("cycle_a.js") }
      assert_nothing_raised { graph.tree_sha("cycle_b.js") }
    end
  end

  test "cyclic imports produce valid hashes" do
    with_cycle_handler do |_handler, graph|
      sha_a = graph.tree_sha("cycle_a.js")
      sha_b = graph.tree_sha("cycle_b.js")
      assert_match(/\A[0-9a-f]{8}\z/, sha_a)
      assert_match(/\A[0-9a-f]{8}\z/, sha_b)
    end
  end

  test "cyclic imports get the same hash" do
    with_cycle_handler do |_handler, graph|
      sha_a = graph.tree_sha("cycle_a.js")
      sha_b = graph.tree_sha("cycle_b.js")
      assert_equal sha_a, sha_b, "Cycle members should share the same hash"
    end
  end

  test "changing one cycle member updates the other" do
    with_cycle_handler do |handler, graph|
      sha_b_before = graph.tree_sha("cycle_b.js")

      abs_a = handler.resolve_file("cycle_a.js")
      File.write(abs_a, File.read(abs_a) + "\n// modified")
      FileUtils.touch(abs_a, mtime: Time.now + 1)

      sha_b_after = graph.tree_sha("cycle_b.js")
      assert_not_equal sha_b_before, sha_b_after,
        "Changing one cycle member should update the other's hash"
    end
  end

  test "file importing a cycle member gets a valid hash" do
    with_cycle_handler do |_handler, graph|
      sha = graph.tree_sha("uses_cycle.js")
      assert_match(/\A[0-9a-f]{8}\z/, sha)
      assert_not_equal sha, graph.tree_sha("cycle_a.js"),
        "Non-cycle file should have a different hash from the cycle"
    end
  end

  # --- Asset#stale? and Asset#deleted? ---

  test "Asset#stale? is false for unchanged file" do
    asset = @graph["js/root_b.js"]
    refute asset.stale?
  end

  test "Asset#deleted? is false for existing file" do
    asset = @graph["js/root_b.js"]
    refute asset.deleted?
  end

  test "Asset#stale? is true after mtime change" do
    with_tmpdir_handler do |handler, graph|
      asset = graph["js/leaf/alpha_one.js"]
      abs = handler.resolve_file("js/leaf/alpha_one.js")
      FileUtils.touch(abs, mtime: Time.now + 1)
      assert asset.stale?
    end
  end

  test "Asset#deleted? is true after file removal" do
    with_tmpdir_handler do |handler, graph|
      asset = graph["js/leaf/alpha_one.js"]
      File.delete(handler.resolve_file("js/leaf/alpha_one.js"))
      assert asset.deleted?
      assert asset.stale?
    end
  end

  private

  # Creates a tmpdir with a copy of the JS fixtures for mutation-safe tests.
  def with_tmpdir_handler
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.expand_path("../../dummy/app/assets/js", __FILE__), File.join(dir, "js"))
      handler = Assiette::AssetHandler.new(root: dir)
      yield handler, handler.dependency_graph
    end
  end

  # Creates a tmpdir with cyclic JS imports: cycle_a -> cycle_b -> cycle_a,
  # plus a non-cycle file that imports cycle_a.
  def with_cycle_handler
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "cycle_a.js"), <<~JS)
        import {b} from "./cycle_b.js"
        export function a() { return "a" + b() }
      JS
      File.write(File.join(dir, "cycle_b.js"), <<~JS)
        import {a} from "./cycle_a.js"
        export function b() { return "b" + a() }
      JS
      File.write(File.join(dir, "uses_cycle.js"), <<~JS)
        import {a} from "./cycle_a.js"
        export function main() { return a() }
      JS

      handler = Assiette::AssetHandler.new(root: dir)
      yield handler, handler.dependency_graph
    end
  end
end
