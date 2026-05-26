# frozen_string_literal: true

require_relative "assiette/version"

module Assiette
  autoload :Rewriter, File.expand_path("assiette/rewriter", __dir__)
  autoload :AssetHandler, File.expand_path("assiette/asset_handler", __dir__)
  autoload :Server, File.expand_path("assiette/server", __dir__)
  autoload :Helpers, File.expand_path("assiette/helpers", __dir__)
  autoload :RailsAssetUrlHelper, File.expand_path("assiette/rails_asset_url_helper", __dir__)
end

require_relative "assiette/railtie" if defined?(Rails::Railtie)
