# frozen_string_literal: true

require_relative "assiette/version"
require_relative "assiette/version_tag"
require_relative "assiette/rewriter"
require_relative "assiette/asset_handler"
require_relative "assiette/server"
require_relative "assiette/helpers"
require_relative "assiette/rails_asset_url_helper"
require_relative "assiette/railtie" if defined?(Rails::Railtie)

module Assiette
end
