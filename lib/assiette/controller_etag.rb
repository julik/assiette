# frozen_string_literal: true

module Assiette
  # Extends ActionController::Base with a one-line macro that folds the
  # Assiette apex digest into every ETag the controller generates.
  #
  #   class ApplicationController < ActionController::Base
  #     include_assiette_etags!
  #   end
  #
  # Without this, a page whose ETag is built from the code revision plus model
  # cache keys keeps validating after you edit a stylesheet — neither of those
  # moved — and a caching layer happily serves stored HTML linking the previous
  # ?s= hash.
  module ControllerEtag
    def include_assiette_etags!
      etag do
        # Resolved off the Rack env rather than Rails.application.assets so
        # this works in mode 1 too, and picks the right handler when an engine
        # mounts a second one.
        entry = request.env["assiette.stack"]&.last
        entry[:handler].digest if entry
      end
    end
  end
end
