# frozen_string_literal: true

module Assiette
  module Helpers
    # Returns the URL path to an asset served by Assiette, with a cache-busting
    # version tag appended. Returns nil if no handler in the stack has the file.
    def assiette_asset_path(path)
      entry = assiette_entry_resolving(path)
      return unless entry
      assiette_record_reference(entry[:handler], path)
      entry[:handler].absolute_asset_url_path(path, entry[:script_name])
    end

    # Returns the SRI integrity hash for an asset, computed over the served
    # (rewritten) content. Returns nil if the file is not found.
    def assiette_asset_integrity(path)
      entry = assiette_entry_resolving(path)
      return unless entry
      assiette_record_reference(entry[:handler], path)
      entry[:handler].asset_integrity(path)
    end

    # Generates a <link rel="stylesheet"> tag with SRI integrity.
    def assiette_stylesheet_tag(path)
      tag.link(rel: "stylesheet", href: assiette_asset_path(path),
        integrity: assiette_asset_integrity(path), crossorigin: "anonymous")
    end

    # Generates <link rel="modulepreload"> tags for all detected ES modules
    # under the configured asset roots. Each tag includes an SRI integrity
    # hash computed over the served (rewritten) content.
    #
    # Unlike the path helpers this stays scoped to a single handler — the
    # innermost Server in the stack — on purpose. It renders a listing of
    # everything a handler holds, so walking the stack would put one tenant's
    # file list on another tenant's page.
    def assiette_modulepreload_tags
      entry = assiette_stack.last
      handler = entry[:handler]
      safe_join(handler.js_modules.map { |mod|
        assiette_record_reference(handler, mod[:path])
        tag.link(rel: "modulepreload",
          href: handler.absolute_asset_url_path(mod[:path], entry[:script_name]),
          integrity: mod[:integrity], crossorigin: "anonymous")
      }, "\n")
    end

    # Every asset this response has linked so far, as handler => Set of URL
    # paths. Written by the helpers as they resolve, read after the render by
    # `include_assiette_etags!` to remember what this page links.
    def self.referenced(env)
      env["assiette.referenced"] ||= {}
    end

    def self.record_reference(env, handler, path)
      (referenced(env)[handler] ||= Set.new) << path.sub(%r{\A/}, "")
    end

    private

    def assiette_stack
      stack = request.env["assiette.stack"]
      raise "No Assiette::Server in middleware stack" if stack.nil? || stack.empty?
      stack
    end

    # Walks the stack from the innermost Server outwards and returns the first
    # entry whose handler actually has the file. With one Server mounted that is
    # simply the only entry; with several — an app serving a per-tenant
    # directory next to a shared one — the innermost is not necessarily the one
    # holding the asset a page asks for. Returns nil if none of them has it.
    def assiette_entry_resolving(path)
      assiette_stack.reverse_each.find { |entry| entry[:handler].resolve_file(path) }
    end

    def assiette_record_reference(handler, path)
      Helpers.record_reference(request.env, handler, path)
    end
  end
end
