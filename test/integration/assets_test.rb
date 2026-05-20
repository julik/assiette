# frozen_string_literal: true

require "test_helper"

class AssetsTest < ActionDispatch::IntegrationTest
  test "serves CSS files with correct content type" do
    get "/application.css"
    assert_response :success
    assert_equal "text/css", response.media_type
    assert_includes response.body, "box-sizing"
  end

  test "serves root JS module" do
    get "/js/root_a.js"
    assert_response :success
    assert_equal "application/javascript", response.media_type
    assert_includes response.body, "initA"
  end

  test "serves mid-level JS module" do
    get "/js/mid/alpha.js"
    assert_response :success
    assert_equal "application/javascript", response.media_type
    assert_includes response.body, "alphaOne"
  end

  test "serves leaf JS module" do
    get "/js/leaf/alpha_one.js"
    assert_response :success
    assert_equal "application/javascript", response.media_type
    assert_includes response.body, "alphaOne"
  end

  test "serves files from public/ root" do
    get "/logo.png"
    assert_response :success
    assert_equal "image/png", response.media_type
  end

  test "returns 404 for non-existent files" do
    get "/nonexistent.js"
    assert_response :not_found
  end

  test "returns 404 for disallowed file types" do
    get "/some/file.html"
    assert_response :not_found
  end

  test "prevents path traversal attacks" do
    get "/../../../etc/passwd"
    assert_response :not_found
  end

  test "sets long cache expiry header" do
    get "/application.css"
    assert_response :success
    assert_match(/max-age=\d+/, response.headers["Cache-Control"])
    assert_includes response.headers["Cache-Control"], "public"
  end

  # --- Import rewriting cascades through the dependency graph ---

  test "rewrites root module imports with version tag" do
    get "/js/root_a.js?v=abc"
    assert_response :success
    assert_includes response.body, './mid/alpha.js?v=abc"'
    assert_includes response.body, './mid/beta.js?v=abc"'
    assert_includes response.body, './mid/gamma.js?v=abc"'
  end

  test "rewrites mid-level dot-dot imports with version tag" do
    get "/js/mid/alpha.js?v=xyz"
    assert_response :success
    assert_includes response.body, '../leaf/alpha_one.js?v=xyz"'
    assert_includes response.body, '../leaf/alpha_two.js?v=xyz"'
  end

  test "leaf modules have no imports to rewrite" do
    get "/js/leaf/alpha_one.js?v=tag1"
    assert_response :success
    assert_not_includes response.body, "?v=tag1"
  end

  test "rewrites imports even without explicit version tag in request" do
    get "/js/root_a.js"
    assert_response :success
    assert_includes response.body, "?v="
  end

  test "standalone root module is served without import rewriting" do
    get "/js/root_b.js?v=nope"
    assert_response :success
    assert_not_includes response.body, "?v=nope"
  end

  # --- CSS rewriting ---

  test "does not rewrite CSS without url() even with version tag" do
    get "/application.css?v=abc123"
    assert_response :success
    assert_not_includes response.body, "?v="
  end

  test "rewrites url() in CSS when version tag is present" do
    get "/test_with_url.css?v=r42"
    assert_response :success
    assert_equal "text/css", response.media_type
    assert_includes response.body, "url(./images/icon.svg?v=r42)"
  end

  test "rewrites url() in CSS even without explicit version tag" do
    get "/test_with_url.css"
    assert_response :success
    assert_includes response.body, "?v="
  end

  # --- ETag stability ---

  test "etag is stable regardless of version tag" do
    get "/js/root_a.js?v=v1"
    etag_v1 = response.headers["ETag"]

    get "/js/root_a.js?v=v2"
    etag_v2 = response.headers["ETag"]

    assert_equal etag_v1, etag_v2, "ETag should be computed from the raw file, not the rewritten content"
  end
end
