# frozen_string_literal: true

require_relative "boot"

require "action_controller/railtie"
require "action_view/railtie"
require "action_dispatch/railtie"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)
require "assiette" # All Assiette modules auto-resolve from here

module Dummy
  class Application < Rails::Application
    config.load_defaults 7.2
    config.eager_load = false
    config.root = File.expand_path("..", __dir__)
    config.middleware.use Assiette::Server, Assiette::AssetHandler.new(
      root: File.expand_path("../app/assets", __dir__),
      additional_directory_mappings: {"/" => File.expand_path("../public", __dir__)}
    )
    # vendor/counter_gem stands in for a gem, which exposes its directory as "@counter" the
    # way a gem does from its Railtie
    initializer "counter_gem.assiette" do
      ActiveSupport.on_load(:assiette) { expose "@counter", File.expand_path("../vendor/counter_gem", __dir__) }
    end
  end
end
