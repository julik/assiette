# frozen_string_literal: true

require "rails/railtie"

module Assiette
  class Railtie < ::Rails::Railtie
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
