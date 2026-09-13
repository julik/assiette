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
        if resolved
          # image_tag and friends go through here, so this is where a page
          # rendering in mode 2 declares what it links. No request means no
          # response to fold the reference into — a mailer, say.
          env = (request&.env if respond_to?(:request))
          Assiette::Helpers.record_reference(env, resolver, source) if env
          return resolved
        end
      end
      super
    end
  end
end
