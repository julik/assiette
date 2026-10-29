# frozen_string_literal: true

require "pathname"

module Assiette
  module Rewriter
    # Matches quoted strings that look like relative/absolute JS import paths.
    # Handles ./  ../  /  but NOT protocol-relative //, and "@handle/..." for a
    # directory exposed with AssetHandler#expose
    # $1 = quote char, $2 = path including extension
    JS_IMPORT_RE = /(["'])((?:\.{0,2}\/(?!\/)|@[\w.-]+\/)[^"']*\.(?:js|mjs|es))\1/

    # Matches url() in CSS with relative/absolute paths.
    # Handles url(./path), url("./path"), url('../path'), url(/path)
    # but NOT url(data:...), url(https://...), url(//...)
    # $1 = opening (quote or empty), $2 = path, $3 = closing (quote or empty)
    CSS_URL_RE = /url\((\s*["']?)(\.{0,2}\/(?!\/)[^)"']*?)(\s*["']?\s*)\)/

    module_function

    # Rewrites JS imports with per-import hashes via a block.
    # The block receives the import path and returns the hash for that import,
    # or nil to leave the import unversioned.
    #
    # An "@handle/..." import that gets a hash is also turned into a path
    # relative to `from` - the URL path of the file being rewritten - since a
    # browser cannot resolve a bare "@handle" without an import map. Relative,
    # so it keeps working under whatever SCRIPT_NAME the handler is mounted at.
    # One that gets no hash is left as written, for an import map to resolve.
    def rewrite_js_imports(source, from: "", &block)
      source.gsub(JS_IMPORT_RE) do
        quote = $1
        path = $2
        hash = yield(path)
        next "#{quote}#{path}#{quote}" unless hash
        path = relative_to(from, path) if path.start_with?("@")
        "#{quote}#{path}?s=#{hash}#{quote}"
      end
    end

    # "@x/y.js" as seen from the directory of `from`, always starting with ./
    # or ../ - "y.js" alone would be a bare specifier again
    def relative_to(from, path)
      relative = Pathname.new(path).relative_path_from(Pathname.new(File.dirname(from))).to_s
      relative.start_with?("../") ? relative : "./#{relative}"
    end

    # Rewrites CSS url() references with per-url hashes via a block.
    # The block receives the url path and returns the hash for that url,
    # or nil to leave the url unversioned.
    def rewrite_css_urls(source, &block)
      source.gsub(CSS_URL_RE) do
        open = $1
        path = $2
        close = $3
        hash = yield(path)
        hash ? "url(#{open}#{path}?s=#{hash}#{close})" : "url(#{open}#{path}#{close})"
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
