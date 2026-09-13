# frozen_string_literal: true

require "test_helper"

# End to end behaviour of `include_assiette_etags!` in its default
# `digest: :referenced` mode: what a page links decides its ETag, and what a
# page links is learned by rendering it once.
class ReferencedEtagTest < ActionDispatch::IntegrationTest
  setup { handler_for_dummy_app.reference_log.clear }

  test "the first render of a page has nothing remembered and falls back to the whole-handler digest" do
    get "/referenced/css"
    assert_response :success
    cold = response.headers["ETag"]

    assert_equal ["application.css"], handler_for_dummy_app.reference_log[reference_key("/referenced/css")],
      "the render is what teaches the log; it runs after the ETag was already built"

    get "/referenced/css"
    warm = response.headers["ETag"]

    assert_not_equal cold, warm,
      "the second request folds in the page's own links instead of the whole handler"
  end

  test "the ETag is stable once the page has been rendered, and still 304s" do
    get "/referenced/css"
    get "/referenced/css"
    warm = response.headers["ETag"]

    get "/referenced/css"
    assert_equal warm, response.headers["ETag"]

    get "/referenced/css", headers: {"HTTP_IF_NONE_MATCH" => warm}
    assert_response :not_modified
  end

  test "two pages behind the same validator get different ETags because they link different assets" do
    2.times { get "/referenced/css" }
    css_page = response.headers["ETag"]

    2.times { get "/referenced/image" }
    image_page = response.headers["ETag"]

    assert_not_equal css_page, image_page,
      "both call fresh_when(etag: \"fixed\") — under the apex digest these would collide"
  end

  test "the warm ETag is a function of exactly what the page linked" do
    handler = handler_for_dummy_app
    key = reference_key("/referenced/image")

    2.times { get "/referenced/image" }
    warm = response.headers["ETag"]
    assert_equal ["logo.png"], handler.reference_log[key]

    # Lie to the log about what this page links. Nothing else changes — same
    # route, same validator, same assets on disk — so if the ETag moves, the
    # remembered set is what it is built from.
    handler.reference_log.record(key, ["application.css"])
    get "/referenced/image"
    assert_not_equal warm, response.headers["ETag"]

    assert_equal ["logo.png"], handler.reference_log[key], "and that render corrected the lie"
    get "/referenced/image"
    assert_equal warm, response.headers["ETag"]
  end

  test "a 304 leaves the remembered set alone" do
    2.times { get "/referenced/css" }
    warm = response.headers["ETag"]

    get "/referenced/css", headers: {"HTTP_IF_NONE_MATCH" => warm}
    assert_response :not_modified

    assert_equal ["application.css"], handler_for_dummy_app.reference_log[reference_key("/referenced/css")],
      "nothing rendered, so nothing was linked — clobbering the set with [] would " \
      "change the ETag and break the very validation that just succeeded"

    get "/referenced/css"
    assert_equal warm, response.headers["ETag"]
  end

  test "modulepreload tags count as links" do
    2.times { get "/smoke" }
    assert_response :success

    # /smoke has no fresh_when, so nothing is remembered for it — but the
    # helpers still declared what they resolved into the env.
    linked = Assiette::Helpers.referenced(request.env).values.first

    assert_includes linked, "application.css"
    assert_includes linked, "js/root_a.js"
    assert_includes linked, "js/mid/alpha.js",
      "assiette_modulepreload_tags lists every module, and every one of them is on the page"
  end

  test "digest: :all keeps folding in the whole-handler digest from the first request on" do
    handler = handler_for_dummy_app

    get "/all_digest/css"
    first = response.headers["ETag"]
    get "/all_digest/css"

    assert_equal first, response.headers["ETag"], "no warm-up: the value does not depend on a render"
    assert_nil handler.reference_log[reference_key("/all_digest/css")],
      "the :all mode installs no after_action, so it remembers nothing"
  end

  private

  def handler_for_dummy_app
    get "/smoke" unless integration_session.request
    request.env["assiette.stack"].last[:handler]
  end

  def reference_key(path)
    "www.example.com#{path}\0text/html"
  end
end
