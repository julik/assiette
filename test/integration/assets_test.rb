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

  # --- Import rewriting with per-file content hashes ---

  test "rewrites root module imports with per-dep content hashes" do
    get "/js/root_a.js"
    assert_response :success
    # Each import gets its own 8-char hex hash
    assert_match %r{./mid/alpha\.js\?s=[0-9a-f]{8}"}, response.body
    assert_match %r{./mid/beta\.js\?s=[0-9a-f]{8}"}, response.body
    assert_match %r{./mid/gamma\.js\?s=[0-9a-f]{8}"}, response.body
  end

  test "rewrites mid-level imports with per-dep content hashes" do
    get "/js/mid/alpha.js"
    assert_response :success
    assert_match %r{\.\./leaf/alpha_one\.js\?s=[0-9a-f]{8}"}, response.body
    assert_match %r{\.\./leaf/alpha_two\.js\?s=[0-9a-f]{8}"}, response.body
  end

  test "each import gets its own unique hash" do
    get "/js/mid/alpha.js"
    assert_response :success
    alpha_one_hash = response.body[/alpha_one\.js\?s=([0-9a-f]{8})/, 1]
    alpha_two_hash = response.body[/alpha_two\.js\?s=([0-9a-f]{8})/, 1]
    assert alpha_one_hash, "alpha_one hash should be present"
    assert alpha_two_hash, "alpha_two hash should be present"
    assert_not_equal alpha_one_hash, alpha_two_hash, "Different files should have different hashes"
  end

  test "leaf modules have no imports to rewrite" do
    get "/js/leaf/alpha_one.js"
    assert_response :success
    assert_not_includes response.body, "?s="
  end

  test "standalone root module is served without import rewriting" do
    get "/js/root_b.js"
    assert_response :success
    assert_not_includes response.body, "?s="
  end

  # --- CSS rewriting ---

  test "does not rewrite CSS without url()" do
    get "/application.css"
    assert_response :success
    assert_not_includes response.body, "?s="
  end

  test "rewrites url() in CSS with content hash" do
    get "/test_with_url.css"
    assert_response :success
    assert_equal "text/css", response.media_type
    assert_match %r{url\(./images/icon\.svg\?s=[0-9a-f]{8}\)}, response.body
  end

  # --- ETag stability ---

  test "etag is stable across requests" do
    get "/js/root_a.js"
    etag_v1 = response.headers["ETag"]

    get "/js/root_a.js"
    etag_v2 = response.headers["ETag"]

    assert_equal etag_v1, etag_v2, "ETag should be stable for the same raw file"
  end

  # --- Query string is ignored for rewriting ---

  test "query string s= param does not affect rewriting" do
    get "/js/root_a.js"
    body_without = response.body

    get "/js/root_a.js?s=anything"
    body_with = response.body

    assert_equal body_without, body_with, "Rewriting should use dependency graph, not query param"
  end
end
