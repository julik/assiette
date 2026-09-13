# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

# `include_assiette_etags!` folds in every handler that saw the request, not
# only the innermost one.
#
# The view helpers search the whole stack, so a page served by an app with two
# Servers mounted can link an asset the outer handler holds. Digesting only the
# innermost would leave that page validating after that asset changed.
#
# A controller test rather than an integration test, so the handlers can be
# throwaway copies of the fixtures — editing files under a real asset root
# would race with every other test in the suite. `env["assiette.stack"]` is
# exactly what two mounted Servers would have left there.
class ControllerEtagStackTest < ActionController::TestCase
  tests EtagController

  setup do
    @outer_dir = Dir.mktmpdir
    @inner_dir = Dir.mktmpdir
    FileUtils.cp(File.expand_path("../dummy/app/assets/application.css", __dir__), @outer_dir)
    FileUtils.cp_r(File.expand_path("../dummy/app/assets/js", __dir__), File.join(@inner_dir, "js"))

    @outer = Assiette::AssetHandler.new(root: @outer_dir)
    @inner = Assiette::AssetHandler.new(root: @inner_dir)
    @request.env["assiette.stack"] = [
      {handler: @outer, script_name: ""},
      {handler: @inner, script_name: ""}
    ]
  end

  teardown { [@outer_dir, @inner_dir].each { |dir| FileUtils.remove_entry(dir) } }

  test "an asset in the innermost handler moves the ETag" do
    get :show
    before = response.headers["ETag"]

    edit_in_place File.join(@inner_dir, "js/leaf/alpha_one.js")

    get :show
    assert_not_equal before, response.headers["ETag"]
  end

  test "an asset in an outer handler moves the ETag too" do
    get :show
    before = response.headers["ETag"]

    edit_in_place File.join(@outer_dir, "application.css")

    get :show
    assert_not_equal before, response.headers["ETag"],
      "the helpers would happily link this asset, so a page can be carrying its URL"
  end

  test "the ETag is stable when nothing changes" do
    get :show
    assert_equal response.headers["ETag"], (get(:show) && response.headers["ETag"])
  end

  test "no Assiette in the stack contributes nothing" do
    @request.env.delete("assiette.stack")

    get :show
    assert_response :success
    assert response.headers["ETag"].present?, "the controller's own validator still stands"
  end

  private

  # Appends to a file without disturbing the mtime of the directory holding it.
  def edit_in_place(abs)
    File.write(abs, File.read(abs) + "\n/* edited */")
    FileUtils.touch(abs, mtime: Time.now + 1)
  end
end
