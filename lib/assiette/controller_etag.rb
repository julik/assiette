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
  #
  # The value folded in covers every asset the request's handlers can serve,
  # rather than the ones this particular page happens to link. That is the
  # coarse answer, and it is the only one available before the template runs:
  # `etag` blocks are evaluated inside `fresh_when`, in the action, and skipping
  # the render is the entire point of a conditional GET. A page that wants a
  # narrower validator can name its entry points and pass
  # AssetHandler#digest_for to fresh_when itself.
  module ControllerEtag
    def include_assiette_etags!
      etag do
        # Every handler that saw the request, not only the innermost one. The
        # view helpers resolve an asset against the whole stack, so a page can
        # link assets an outer handler serves — and a change to one of those
        # has to move this page's ETag just the same.
        #
        # Resolved off the Rack env rather than Rails.application.assets so
        # this works in mode 1 too.
        stack = request.env["assiette.stack"]
        stack.map { |entry| entry[:handler].digest }.join("/") if stack&.any?
      end
    end
  end
end
