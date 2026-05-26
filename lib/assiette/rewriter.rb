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

    # Rewrites JS imports with per-import hashes via a block.
    # The block receives the import path and must return the hash for that import.
    def rewrite_js_imports(source, &block)
      source.gsub(JS_IMPORT_RE) do
        quote = $1
        path = $2
        hash = yield(path)
        "#{quote}#{path}?s=#{hash}#{quote}"
      end
    end

    # Rewrites CSS url() references with per-url hashes via a block.
    # The block receives the url path and must return the hash for that url.
    def rewrite_css_urls(source, &block)
      source.gsub(CSS_URL_RE) do
        open = $1
        path = $2
        close = $3
        hash = yield(path)
        "url(#{open}#{path}?s=#{hash}#{close})"
      end
    end

    # Returns an array of import paths found in JS source.
    def extract_js_imports(source)
      source.scan(JS_IMPORT_RE).map { |m| m[1] }
    end

    # Returns an array of url() paths found in CSS source.
    def extract_css_urls(source)
      source.scan(CSS_URL_RE).map { |m| m[1] }
    end
  end
end
