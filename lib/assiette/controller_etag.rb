# frozen_string_literal: true

module Assiette
  # Extends ActionController::Base with a one-line macro that folds an Assiette
  # digest into every ETag the controller generates.
  #
  #   class ApplicationController < ActionController::Base
  #     include_assiette_etags!
  #   end
  #
  # Without this, a page whose ETag is built from the code revision plus model
  # cache keys keeps validating after you edit a stylesheet — neither of those
  # moved — and a caching layer happily serves stored HTML linking the previous
  # ?s= hash.
  #
  # Which digest gets folded in is the `digest:` argument:
  #
  #   :referenced (default) — a hash over the assets this page linked the last
  #     time this process rendered it. Editing an asset the page does not link
  #     leaves the page validating.
  #   :all — AssetHandler#digest, one hash over every asset the handler can
  #     serve. Any change anywhere busts every page.
  #
  # :referenced has to work around an ordering problem: Rails evaluates `etag`
  # blocks inside `fresh_when`, in the action, before the template renders, so
  # the set of assets this response is about to link does not exist yet. The
  # macro therefore reads the set the previous render of the same page left in
  # the handler's ReferenceLog, and installs an after_action to write this
  # render's set back. Until this process has rendered a given page once there
  # is nothing to read, and it falls back to :all — never something weaker.
  module ControllerEtag
    # Instance-side of the macro. Mixed into the controller by
    # include_assiette_etags!, because ControllerEtag itself is extended onto
    # ActionController::Base and so only carries class methods.
    module Digesting
      private

      # Resolved off the Rack env rather than Rails.application.assets so this
      # works in mode 1 too, and picks the right handler when an engine mounts
      # a second one.
      def assiette_etag_handler
        request.env["assiette.stack"]&.last&.[](:handler)
      end

      # Identifies "the same page" across requests. The query string is left
      # out deliberately: it varies with tracking parameters that change
      # nothing about which assets a template links, and every distinct value
      # would take its own slot in the log.
      def assiette_reference_key
        "#{request.host}#{request.path}\0#{request.format}"
      end
    end

    def include_assiette_etags!(digest: :referenced)
      unless %i[referenced all].include?(digest)
        raise ArgumentError, "digest: must be :referenced or :all, got #{digest.inspect}"
      end
      include Digesting

      etag do
        handler = assiette_etag_handler
        if handler.nil?
          nil
        elsif digest == :all
          handler.digest
        else
          remembered = handler.reference_log[assiette_reference_key]
          remembered ? handler.digest_for(remembered) : handler.digest
        end
      end

      return if digest == :all

      after_action do
        handler = assiette_etag_handler
        linked = handler && Assiette::Helpers.referenced(request.env)[handler]
        # A 304 renders nothing and links nothing. Leaving the previous set in
        # place is the whole point — it is what produced the matching ETag.
        handler.reference_log.record(assiette_reference_key, linked) if linked
      end
    end
  end
end
