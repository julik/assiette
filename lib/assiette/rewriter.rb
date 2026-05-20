# frozen_string_literal: true

module Assiette
  module Rewriter
    # Matches quoted strings that look like relative/absolute JS import paths.
    # Handles ./  ../  /  but NOT protocol-relative //
    # $1 = quote char, $2 = path including extension
    JS_IMPORT_RE = /(["'])(\.{0,2}\/(?!\/)[^"']*\.(?:js|mjs|es))\1/

    # Matches url() in CSS with relative/absolute paths.
    # Handles url(./path), url("./path"), url('../path'), url(/path)
    # but NOT url(data:...), url(https://...), url(//...)
    # $1 = opening (quote or empty), $2 = path, $3 = closing (quote or empty)
    CSS_URL_RE = /url\((\s*["']?)(\.{0,2}\/(?!\/)[^)"']*?)(\s*["']?\s*)\)/

    module_function

    def rewrite_js_imports(source, version_tag)
      source.gsub(JS_IMPORT_RE) do
        "#{$1}#{$2}?v=#{version_tag}#{$1}"
      end
    end

    def rewrite_css_urls(source, version_tag)
      source.gsub(CSS_URL_RE) do
        "url(#{$1}#{$2}?v=#{version_tag}#{$3})"
      end
    end
  end
end
