# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# AssetHandler#digest_for hashes exactly the nodes it is handed, leaning on the
# fingerprints already cascading up the graph: naming a root module covers
# everything that module imports, without naming any of it.
class ReferencedDigestTest < ActiveSupport::TestCase
  setup do
    @handler = Assiette::AssetHandler.new(
      root: File.expand_path("../../dummy/app/assets", __FILE__),
      additional_directory_mappings: {"/" => File.expand_path("../../dummy/public", __FILE__)}
    )
  end

  test "digest_for returns a 16-char hex hash" do
    assert_match(/\A[0-9a-f]{16}\z/, @handler.digest_for(["/application.css"]))
  end

  test "digest_for is stable across repeated calls" do
    assert_equal @handler.digest_for(["/application.css"]), @handler.digest_for(["/application.css"])
  end

  test "digest_for does not depend on the order or duplication of its input" do
    one = @handler.digest_for(["/application.css", "/js/root_a.js"])
    two = @handler.digest_for(["js/root_a.js", "/application.css", "/js/root_a.js"])

    assert_equal one, two,
      "the same set of links must hash the same however the page happened to emit it"
  end

  test "different sets of links hash differently" do
    assert_not_equal @handler.digest_for(["/application.css"]),
      @handler.digest_for(["/js/root_a.js"])
  end

  test "digest_for over no links at all is still a hash" do
    assert_match(/\A[0-9a-f]{16}\z/, @handler.digest_for([]))
  end

  # --- the point of the exercise ---

  test "naming a root module covers every file it imports" do
    with_tmpdir_handler do |handler, _dir|
      before = handler.digest_for(["js/root_a.js"])
      edit_in_place handler.resolve_file("js/leaf/alpha_one.js")

      assert_not_equal before, handler.digest_for(["js/root_a.js"]),
        "root_a.js does not import alpha_one.js directly — its fingerprint reaches it, " \
        "which is what lets one named node stand in for a whole subtree"
    end
  end

  test "an asset the page does not link leaves its digest alone" do
    with_tmpdir_handler do |handler, _dir|
      before = handler.digest_for(["js/root_b.js"])
      edit_in_place handler.resolve_file("js/leaf/beta_one.js")

      assert_equal before, handler.digest_for(["js/root_b.js"]),
        "beta_one.js hangs off root_a.js; a page linking only root_b.js must keep validating"
      assert_not_equal before, handler.digest_for(["js/root_a.js"]),
        "and the page that does link it must not"
    end
  end

  test "the apex digest busts on a change the page has nothing to do with" do
    with_tmpdir_handler do |handler, _dir|
      before = handler.digest
      edit_in_place handler.resolve_file("js/leaf/beta_one.js")

      assert_not_equal before, handler.digest,
        "this is the behaviour digest_for trades away: every page busts on every change"
    end
  end

  test "digest_for moves when a linked asset is deleted" do
    with_tmpdir_handler do |handler, dir|
      before = handler.digest_for(["js/root_a.js", "js/root_b.js"])
      FileUtils.rm(File.join(dir, "js/root_b.js"))

      assert_not_equal before, handler.digest_for(["js/root_a.js", "js/root_b.js"]),
        "a link that no longer resolves must not hash the same as one that did"
    end
  end

  test "digest_for hashes the path, so a rename moves it" do
    with_tmpdir_handler do |handler, dir|
      before = handler.digest_for(["js/root_a.js"])
      FileUtils.mv(File.join(dir, "js/root_a.js"), File.join(dir, "js/root_c.js"))

      assert_not_equal before, handler.digest_for(["js/root_c.js"]),
        "identical bytes under a new name are a different page: the src changed"
    end
  end

  test "digest_for needs no populated graph, unlike the apex digest" do
    with_tmpdir_handler do |handler, _dir|
      cold = handler.digest_for(["js/root_a.js"])
      handler.digest # populates the graph fully
      warm = handler.digest_for(["js/root_a.js"])

      assert_equal cold, warm,
        "the named nodes are the whole input — what else the process has served cannot matter"
    end
  end

  private

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

class ReferenceLogTest < ActiveSupport::TestCase
  setup { @log = Assiette::ReferenceLog.new }

  test "an unrecorded key reads as nil, not as an empty set" do
    assert_nil @log["/page"]
  end

  test "a recorded key reads back sorted" do
    @log.record("/page", ["b.css", "a.css"])

    assert_equal ["a.css", "b.css"], @log["/page"]
  end

  test "recording an empty set is remembered as such" do
    @log.record("/page", [])

    assert_equal [], @log["/page"],
      "a page that links nothing has been rendered — that is not the same as never seen"
  end

  test "recording twice replaces the previous set" do
    @log.record("/page", ["a.css"])
    @log.record("/page", ["b.css"])

    assert_equal ["b.css"], @log["/page"]
  end

  test "the log is bounded and drops the least recently recorded key" do
    log = Assiette::ReferenceLog.new(limit: 2)
    log.record("/one", ["a.css"])
    log.record("/two", ["b.css"])
    log.record("/three", ["c.css"])

    assert_equal 2, log.size
    assert_nil log["/one"]
    assert_equal ["c.css"], log["/three"]
  end

  test "re-recording a key keeps it from being evicted" do
    log = Assiette::ReferenceLog.new(limit: 2)
    log.record("/one", ["a.css"])
    log.record("/two", ["b.css"])
    log.record("/one", ["a.css"])
    log.record("/three", ["c.css"])

    assert_equal ["a.css"], log["/one"], "a page still in active use must outlive an idle one"
    assert_nil log["/two"]
  end
end
