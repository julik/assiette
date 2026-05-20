# frozen_string_literal: true

require "test_helper"

class RewriterTest < ActiveSupport::TestCase
  # --- JS import rewriting ---

  test "JS: rewrites double-quoted relative import" do
    assert_rewrite_js 'from "./foo.js"', 'from "./foo.js?v=abc"'
  end

  test "JS: rewrites single-quoted relative import" do
    assert_rewrite_js "from './bar.mjs'", "from './bar.mjs?v=abc'"
  end

  test "JS: rewrites dot-dot-relative import" do
    assert_rewrite_js 'from "../utils/helpers.js"', 'from "../utils/helpers.js?v=abc"'
  end

  test "JS: rewrites absolute import" do
    assert_rewrite_js 'from "/lib/thing.es"', 'from "/lib/thing.es?v=abc"'
  end

  test "JS: does not rewrite bare specifiers" do
    assert_rewrite_js 'from "lodash"', 'from "lodash"'
  end

  test "JS: does not rewrite protocol-relative URLs" do
    assert_rewrite_js 'from "//cdn.example.com/foo.js"', 'from "//cdn.example.com/foo.js"'
  end

  test "JS: does not rewrite https URLs" do
    assert_rewrite_js 'from "https://cdn.example.com/foo.js"', 'from "https://cdn.example.com/foo.js"'
  end

  # --- CSS url() rewriting ---

  test "CSS: rewrites unquoted relative url()" do
    assert_rewrite_css "url(./images/bg.png)", "url(./images/bg.png?v=abc)"
  end

  test "CSS: rewrites double-quoted relative url()" do
    assert_rewrite_css 'url("./fonts/sans.woff2")', 'url("./fonts/sans.woff2?v=abc")'
  end

  test "CSS: rewrites single-quoted relative url()" do
    assert_rewrite_css "url('./icons/check.svg')", "url('./icons/check.svg?v=abc')"
  end

  test "CSS: rewrites dot-dot-relative url()" do
    assert_rewrite_css "url(../shared/reset.css)", "url(../shared/reset.css?v=abc)"
  end

  test "CSS: rewrites absolute url()" do
    assert_rewrite_css "url(/assets/logo.png)", "url(/assets/logo.png?v=abc)"
  end

  test "CSS: does not rewrite data: URIs" do
    input = "url(data:image/svg+xml;base64,ABC)"
    assert_rewrite_css input, input
  end

  test "CSS: does not rewrite https URLs" do
    input = 'url("https://fonts.googleapis.com/css")'
    assert_rewrite_css input, input
  end

  test "CSS: does not rewrite protocol-relative URLs" do
    input = "url(//cdn.example.com/font.woff)"
    assert_rewrite_css input, input
  end

  test "CSS: preserves surrounding CSS" do
    input = "background: #fff url(./bg.png) no-repeat;"
    expected = "background: #fff url(./bg.png?v=abc) no-repeat;"
    assert_rewrite_css input, expected
  end

  private

  def assert_rewrite_js(input, expected)
    assert_equal expected, Assiette::Rewriter.rewrite_js_imports(input, "abc")
  end

  def assert_rewrite_css(input, expected)
    assert_equal expected, Assiette::Rewriter.rewrite_css_urls(input, "abc")
  end
end
