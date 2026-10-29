# frozen_string_literal: true

require "rails/railtie"

module Assiette
  class Railtie < ::Rails::Railtie
    config.assiette = ActiveSupport::OrderedOptions.new
    # "@handle" => a directory, or several: what the generated initializer
    # exposes on its handler (see AssetHandler#expose). A gem adds its own from
    # an initializer that runs before :load_config_initializers
    config.assiette.exposed = {}

    generators do
      require_relative "../generators/assiette/install/install_generator"
    end

    initializer "assiette.rails_asset_url_helper" do
      ActiveSupport.on_load(:action_view) do
        include Assiette::RailsAssetUrlHelper
      end
    end

    initializer "assiette.controller_etag" do
      ActiveSupport.on_load(:action_controller_base) do
        extend Assiette::ControllerEtag
      end
    end
  end
end
