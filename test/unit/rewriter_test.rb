# frozen_string_literal: true

require "test_helper"

class RewriterTest < ActiveSupport::TestCase
  # --- JS import rewriting ---

  test "JS: rewrites double-quoted relative import" do
    assert_rewrite_js 'from "./foo.js"', 'from "./foo.js?s=abc"'
  end

  test "JS: rewrites single-quoted relative import" do
    assert_rewrite_js "from './bar.mjs'", "from './bar.mjs?s=abc'"
  end

  test "JS: rewrites dot-dot-relative import" do
    assert_rewrite_js 'from "../utils/helpers.js"', 'from "../utils/helpers.js?s=abc"'
  end

  test "JS: rewrites absolute import" do
    assert_rewrite_js 'from "/lib/thing.es"', 'from "/lib/thing.es?s=abc"'
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

  # --- JS import rewriting with per-import hashes ---

  test "JS: block receives each import path and uses its return value" do
    source = 'import "./a.js"\nimport "./b.js"'
    result = Assiette::Rewriter.rewrite_js_imports(source) { |path|
      (path == "./a.js") ? "hash_a" : "hash_b"
    }
    assert_includes result, "./a.js?s=hash_a"
    assert_includes result, "./b.js?s=hash_b"
  end

  # --- JS import extraction ---

  test "extract_js_imports returns array of import paths" do
    source = <<~JS
      import {foo} from "./foo.js"
      import {bar} from "../bar.mjs"
      import "lodash"
    JS
    imports = Assiette::Rewriter.extract_js_imports(source)
    assert_equal ["./foo.js", "../bar.mjs"], imports
  end

  test "extract_js_imports returns empty array when no imports" do
    assert_equal [], Assiette::Rewriter.extract_js_imports("const x = 1")
  end

  # --- CSS url() rewriting ---

  test "CSS: rewrites unquoted relative url()" do
    assert_rewrite_css "url(./images/bg.png)", "url(./images/bg.png?s=abc)"
  end

  test "CSS: rewrites double-quoted relative url()" do
    assert_rewrite_css 'url("./fonts/sans.woff2")', 'url("./fonts/sans.woff2?s=abc")'
  end

  test "CSS: rewrites single-quoted relative url()" do
    assert_rewrite_css "url('./icons/check.svg')", "url('./icons/check.svg?s=abc')"
  end

  test "CSS: rewrites dot-dot-relative url()" do
    assert_rewrite_css "url(../shared/reset.css)", "url(../shared/reset.css?s=abc)"
  end

  test "CSS: rewrites absolute url()" do
    assert_rewrite_css "url(/assets/logo.png)", "url(/assets/logo.png?s=abc)"
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
    expected = "background: #fff url(./bg.png?s=abc) no-repeat;"
    assert_rewrite_css input, expected
  end

  # --- CSS url extraction ---

  test "extract_css_urls returns array of url paths" do
    source = <<~CSS
      .a { background: url(./bg.png); }
      .b { background: url("../other.svg"); }
    CSS
    urls = Assiette::Rewriter.extract_css_urls(source)
    assert_equal ["./bg.png", "../other.svg"], urls
  end

  test "extract_css_urls returns empty array when no urls" do
    assert_equal [], Assiette::Rewriter.extract_css_urls("body { color: red; }")
  end

  private

  def assert_rewrite_js(input, expected)
    assert_equal expected, Assiette::Rewriter.rewrite_js_imports(input) { "abc" }
  end

  def assert_rewrite_css(input, expected)
    assert_equal expected, Assiette::Rewriter.rewrite_css_urls(input) { "abc" }
  end
end
