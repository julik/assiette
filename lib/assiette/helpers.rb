# frozen_string_literal: true

module Assiette
  module Helpers
    # Returns the URL path to an asset served by Assiette, with a cache-busting
    # version tag appended.
    def assiette_asset_path(path)
      entry = request.env["assiette.stack"]&.last
      raise "No Assiette::Server in middleware stack" unless entry
      entry[:server].absolute_asset_url_path(path, entry[:script_name])
    end

    # Returns the SRI integrity hash for an asset, computed over the served
    # (rewritten) content. Returns nil if the file is not found.
    def assiette_asset_integrity(path)
      entry = request.env["assiette.stack"]&.last
      raise "No Assiette::Server in middleware stack" unless entry
      entry[:server].asset_integrity(path)
    end

    # Generates a <link rel="stylesheet"> tag with SRI integrity.
    def assiette_stylesheet_tag(path)
      tag.link(rel: "stylesheet", href: assiette_asset_path(path),
        integrity: assiette_asset_integrity(path), crossorigin: "anonymous")
    end

    # Generates <link rel="modulepreload"> tags for all detected ES modules
    # under the configured asset roots. Each tag includes an SRI integrity
    # hash computed over the served (rewritten) content.
    def assiette_modulepreload_tags
      entry = request.env["assiette.stack"]&.last
      raise "No Assiette::Server in middleware stack" unless entry
      modules = entry[:server].js_modules
      safe_join(modules.map { |mod|
        tag.link(rel: "modulepreload", href: assiette_asset_path(mod[:path]),
          integrity: mod[:integrity], crossorigin: "anonymous")
      }, "\n")
    end
  end
end
