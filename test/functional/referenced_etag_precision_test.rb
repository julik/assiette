# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# The claim the whole experiment rests on: a page's ETag follows the assets
# that page links, and nothing else.
#
# These are controller tests rather than integration tests so the handler can
# be a throwaway copy of the fixtures — editing files under a real asset root
# would race with every other test in the suite. Nothing is faked: the
# controller, the etaggers, the after_action and the templates are the real
# ones, and `env["assiette.stack"]` is what the middleware would have put there.
class ReferencedEtagPrecisionTest < ActionController::TestCase
  tests ReferencedEtagController

  setup do
    @dir = Dir.mktmpdir
    FileUtils.cp_r(Dir[File.expand_path("../dummy/app/assets/*", __dir__)], @dir)
    FileUtils.cp(File.expand_path("../dummy/public/logo.png", __dir__), @dir)
    @handler = Assiette::AssetHandler.new(root: @dir)
    @request.env["assiette.stack"] = [{handler: @handler, script_name: ""}]
  end

  teardown { FileUtils.remove_entry(@dir) }

  test "editing the asset the page links busts the page" do
    warm_etag = warm(:css_page)

    edit_in_place File.join(@dir, "application.css")

    get :css_page
    assert_not_equal warm_etag, response.headers["ETag"]
  end

  test "editing an asset the page does not link leaves it validating" do
    warm_etag = warm(:css_page)

    edit_in_place File.join(@dir, "js/leaf/alpha_one.js")

    get :css_page
    assert_equal warm_etag, response.headers["ETag"],
      "alpha_one.js is not on this page — under the whole-handler digest this would bust"

    @request.headers["If-None-Match"] = warm_etag
    get :css_page
    assert_response :not_modified
  end

  test "editing a file two levels below the linked module busts the page" do
    warm_etag = warm(:js_page)

    # The page links js/root_a.js and nothing else. alpha_one.js is imported by
    # js/mid/alpha.js, which root_a.js imports.
    edit_in_place File.join(@dir, "js/leaf/alpha_one.js")

    get :js_page
    assert_not_equal warm_etag, response.headers["ETag"],
      "one named link stands in for its whole import subtree — this is what makes " \
      "naming the referenced nodes enough"
  end

  test "the page that links the module tree and the page that does not are busted apart" do
    js_etag = warm(:js_page)
    css_etag = warm(:css_page)

    edit_in_place File.join(@dir, "js/leaf/alpha_one.js")

    get :css_page
    assert_equal css_etag, response.headers["ETag"]

    get :js_page
    assert_not_equal js_etag, response.headers["ETag"]
  end

  test "two pages linking different assets are busted independently" do
    css_etag = warm(:css_page)
    image_etag = warm(:image_page)

    edit_in_place File.join(@dir, "logo.png")

    get :css_page
    assert_equal css_etag, response.headers["ETag"], "the css page never mentions the logo"

    get :image_page
    assert_not_equal image_etag, response.headers["ETag"]
  end

  # A page that renders a listing depends on which files exist, which no set of
  # remembered paths can describe. Such a page is scoped to the whole handler.

  test "a page rendering modulepreload tags is busted by a module appearing" do
    warm_etag = warm(:preload_page)

    File.write(File.join(@dir, "js/newcomer.js"), "export const newcomer = 1\n")

    get :preload_page
    assert_not_equal warm_etag, response.headers["ETag"],
      "the new module is on the page now — a remembered set of paths would have missed it"
  end

  test "a page naming its links is not busted by a module appearing" do
    warm_etag = warm(:css_page)

    File.write(File.join(@dir, "js/newcomer.js"), "export const newcomer = 1\n")

    get :css_page
    assert_equal warm_etag, response.headers["ETag"],
      "this page lists nothing and links one stylesheet, so a new module is none of its business"
  end

  test "the listing page records the whole-handler marker rather than a set of paths" do
    warm(:preload_page)

    remembered = @handler.reference_log["test.host/referenced/preload\0text/html"]
    assert_includes remembered, Assiette::Helpers::WHOLE_HANDLER
  end

  test "deleting a linked asset busts the page" do
    warm_etag = warm(:css_page)

    FileUtils.rm File.join(@dir, "application.css")

    get :css_page
    assert_not_equal warm_etag, response.headers["ETag"],
      "the link stopped resolving, which is a change to the HTML"
  end

  private

  # Renders once so the page's links are recorded, then again so the ETag is
  # built from the prediction rather than settled into place afterwards. Both
  # produce the same value — that is the point of settling — but the second
  # call is the steady state.
  def warm(action)
    get action
    get action
    response.headers["ETag"]
  end

  # Appends to a file without disturbing the mtime of the directory holding it.
  def edit_in_place(abs)
    File.write(abs, File.read(abs).to_s + "\n/* edited */")
    FileUtils.touch(abs, mtime: Time.now + 1)
  end
end

# The same pages under `digest: :all`, for contrast.
class AllDigestEtagPrecisionTest < ActionController::TestCase
  tests AllDigestEtagController

  setup do
    @dir = Dir.mktmpdir
    FileUtils.cp_r(Dir[File.expand_path("../dummy/app/assets/*", __dir__)], @dir)
    @handler = Assiette::AssetHandler.new(root: @dir)
    @request.env["assiette.stack"] = [{handler: @handler, script_name: ""}]
  end

  teardown { FileUtils.remove_entry(@dir) }

  test "an asset nothing on the page links still busts the page" do
    get :css_page
    before = response.headers["ETag"]

    File.write(File.join(@dir, "js/leaf/alpha_one.js"), "// edited\n")
    FileUtils.touch(File.join(@dir, "js/leaf/alpha_one.js"), mtime: Time.now + 1)

    get :css_page
    assert_not_equal before, response.headers["ETag"],
      "this is the coarseness :referenced trades away"
  end
end
