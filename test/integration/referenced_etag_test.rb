# frozen_string_literal: true

require "test_helper"

# End to end behaviour of `include_assiette_etags!` in its default
# `digest: :referenced` mode.
#
# The invariant these pin down: the prediction decides whether the render can be
# skipped, and the render decides what the client stores. So a wrong prediction
# is visible as a wasted render, and never as a different ETag.
class ReferencedEtagTest < ActionDispatch::IntegrationTest
  setup { handler_for_dummy_app.reference_log.clear }

  test "the render records what the page linked" do
    get "/referenced/css"
    assert_response :success

    assert_equal ["application.css"], handler_for_dummy_app.reference_log[reference_key("/referenced/css")]
  end

  test "a cold worker emits the same ETag as a warm one" do
    get "/referenced/css"
    cold = response.headers["ETag"]

    get "/referenced/css"
    assert_equal cold, response.headers["ETag"],
      "the first render mispredicted — and then corrected the ETag on its way out, " \
      "so a worker that has not seen this page costs a render, not a divergent validator"
  end

  test "the ETag is stable across requests and 304s" do
    get "/referenced/css"
    etag = response.headers["ETag"]

    get "/referenced/css"
    assert_equal etag, response.headers["ETag"]

    get "/referenced/css", headers: {"HTTP_IF_NONE_MATCH" => etag}
    assert_response :not_modified
  end

  test "a correct prediction skips the render entirely" do
    2.times { get "/referenced/css" }
    etag = response.headers["ETag"]

    assert_equal 0, renders_during {
      get "/referenced/css", headers: {"HTTP_IF_NONE_MATCH" => etag}
    }
    assert_response :not_modified
  end

  test "a mispredicted page costs a render, and nothing else" do
    handler = handler_for_dummy_app
    key = reference_key("/referenced/css")

    2.times { get "/referenced/css" }
    etag = response.headers["ETag"]

    # Lie to the log about what this page links. Nothing else changes: same
    # route, same template, same assets on disk.
    handler.reference_log.record(key, ["js/root_a.js"])

    assert_equal 1, renders_during {
      get "/referenced/css", headers: {"HTTP_IF_NONE_MATCH" => etag}
    }, "the prediction no longer reproduces the client's validator, so fresh_when renders"

    assert_equal etag, response.headers["ETag"],
      "and the render settles the ETag back to what the page actually links"
    assert_response :not_modified,
      "which Rack::ConditionalGet then matches against If-None-Match — the render was " \
      "wasted, but the body still does not go over the wire"
    assert_equal ["application.css"], handler.reference_log[key], "the lie is corrected"

    assert_equal 0, renders_during {
      get "/referenced/css", headers: {"HTTP_IF_NONE_MATCH" => etag}
    }, "with the set relearned, the short-circuit is back"
  end

  test "a 304 leaves the remembered set alone" do
    2.times { get "/referenced/css" }
    etag = response.headers["ETag"]

    get "/referenced/css", headers: {"HTTP_IF_NONE_MATCH" => etag}
    assert_response :not_modified

    assert_equal ["application.css"], handler_for_dummy_app.reference_log[reference_key("/referenced/css")],
      "nothing rendered, so nothing was linked — recording that would throw away the " \
      "set that produced the ETag which just validated"
  end

  test "a page that links nothing remembers linking nothing" do
    get "/etagged"
    assert_response :success

    assert_equal [], handler_for_dummy_app.reference_log[reference_key("/etagged")],
      "an empty set is a real answer: this page has no reason to bust when an asset changes"
  end

  test "modulepreload tags count as links" do
    get "/smoke"
    assert_response :success

    # /smoke has no fresh_when, so no ETag is built for it — but the helpers
    # still declared what they resolved into the env.
    linked = Assiette::Helpers.referenced(request.env).values.first

    assert_includes linked, "application.css"
    assert_includes linked, "js/root_a.js"
    assert_includes linked, "js/mid/alpha.js",
      "assiette_modulepreload_tags lists every module, and every one of them is on the page"
  end

  test "digest: :all folds in the whole-handler digest and remembers nothing" do
    handler = handler_for_dummy_app

    get "/all_digest/css"
    first = response.headers["ETag"]
    get "/all_digest/css"

    assert_equal first, response.headers["ETag"], "no warm-up: the value does not depend on a render"
    assert_nil handler.reference_log[reference_key("/all_digest/css")],
      "the :all mode installs no after_action, so it neither records nor settles"
  end

  private

  def handler_for_dummy_app
    get "/smoke" unless integration_session.request
    request.env["assiette.stack"].last[:handler]
  end

  # How many templates were rendered while the block ran. This is the only
  # place the prediction is observable: a wrong one costs a render.
  def renders_during
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("render_template.action_view") { count += 1 }
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def reference_key(path)
    "www.example.com#{path}\0text/html"
  end
end
