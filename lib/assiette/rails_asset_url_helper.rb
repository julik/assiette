# frozen_string_literal: true

module Assiette
  # Include this module into ActionView::Base to make standard Rails asset
  # helpers (image_tag, stylesheet_link_tag, etc.) resolve paths through
  # an Assiette::AssetHandler assigned to Rails.application.assets.
  #
  #   ActiveSupport.on_load(:action_view) do
  #     include Assiette::RailsAssetUrlHelper
  #   end
  module RailsAssetUrlHelper
    def compute_asset_path(source, options = {})
      resolver = Rails.application.assets
      if resolver.is_a?(Assiette::AssetHandler)
        resolved = resolver.absolute_asset_url_path("/#{source}")
        return resolved if resolved
      end
      super
    end
  end
end
