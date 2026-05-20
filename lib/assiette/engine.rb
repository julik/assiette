# frozen_string_literal: true

require "rails/engine"

module Assiette
  class Engine < ::Rails::Engine
    isolate_namespace Assiette

    # Inject helpers into all ActionView contexts so host apps
    # get assiette_asset_path() and assiette_modulepreload_tags() for free
    initializer "assiette.helpers" do
      ActiveSupport.on_load(:action_view) do
        include Assiette::Helpers
      end
    end
  end
end
