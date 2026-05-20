# frozen_string_literal: true

require_relative "boot"

require "action_controller/railtie"
require "action_view/railtie"
require "action_dispatch/railtie"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)
require "assiette"

module Dummy
  class Application < Rails::Application
    config.load_defaults 7.2
    config.eager_load = false
    config.root = File.expand_path("..", __dir__)
    config.middleware.use Assiette::Server,
      root: File.expand_path("../app/assets", __dir__),
      additional_directory_mappings: {"/" => File.expand_path("../public", __dir__)}
  end
end
