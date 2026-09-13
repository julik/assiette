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
  #   :referenced (default) — a hash over the assets the page links. Editing an
  #     asset the page does not link leaves the page validating.
  #   :all — AssetHandler#digest, one hash over every asset the handler can
  #     serve. Any change anywhere busts every page.
  #
  # == Predict, then correct
  #
  # Answering "not modified" without rendering is the entire point of a
  # conditional GET, so the ETag has to exist before the template runs — and
  # before the template runs, which assets it links is not knowable. Two
  # different values do two different jobs here:
  #
  # * Before the render, the macro *predicts* the page's links from what the
  #   last render of the same page left in the handler's ReferenceLog, and
  #   folds the digest of that prediction in. This is the value the 304
  #   decision is made against. With nothing remembered it predicts
  #   AssetHandler#digest instead — coarser, never weaker.
  # * After the render, the true set is known, so the macro reissues the ETag
  #   from it. That is the value the client stores. A worker with a cold log
  #   therefore costs one extra render, not a divergent ETag: every worker
  #   hands out the same validator for the same bytes.
  #
  # So a stale prediction costs revalidations. For it to cost *freshness* the
  # page would have to change which assets it links while everything else in
  # its validator stood still — and Rails already folds the template digest
  # into that validator (ActionController::EtagWithTemplateDigest), so for
  # links that come from the template, it cannot.
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
      # would take its own slot in the log. Two variants of one path that do
      # link different assets share a slot and mispredict each other, which
      # costs a render apiece and nothing else.
      def assiette_reference_key
        "#{request.host}#{request.path}\0#{request.format}"
      end

      def assiette_predict_digest(handler)
        remembered = handler.reference_log[assiette_reference_key]
        @assiette_predicted_digest =
          remembered ? assiette_digest_of(handler, remembered) : handler.digest
      end

      # A page that renders a listing of a handler's assets — the modulepreload
      # tags — depends on which files exist, not just on the ones it happened
      # to name. No set of paths can stand in for that, so such a page is
      # scoped to the whole handler and gets the coarse digest.
      def assiette_digest_of(handler, paths)
        if Helpers.whole_handler?(paths)
          handler.digest
        else
          handler.digest_for(paths)
        end
      end

      # Rails hashes the whole validator list down to one opaque ETag inside
      # fresh_when. Reissuing that ETag after the render means building it from
      # the same list with one element swapped, so the list has to be kept.
      def combine_etags(*, **)
        @assiette_etag_validators = super
      end

      # Called after the action. Records what the render actually linked, and
      # replaces the predicted digest in the ETag with the true one.
      def assiette_settle_etag!
        handler = assiette_etag_handler
        return unless handler
        # A 304 rendered nothing, so it linked nothing. Recording that would
        # throw away the set that produced the ETag which just validated.
        return if response.status == 304

        # An empty set is a real answer, and a useful one: a page that links no
        # assets should not be invalidated by an asset changing.
        linked = Helpers.referenced(request.env)[handler] || []
        handler.reference_log.record(assiette_reference_key, linked)

        return unless @assiette_etag_validators && @assiette_predicted_digest
        truth = assiette_digest_of(handler, linked)
        return if truth == @assiette_predicted_digest

        settled = @assiette_etag_validators.map do |validator|
          (validator == @assiette_predicted_digest) ? truth : validator
        end
        if response.strong_etag?
          response.strong_etag = settled
        else
          response.weak_etag = settled
        end
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
          assiette_predict_digest(handler)
        end
      end

      return if digest == :all

      before_action { Helpers.reset_references(request.env) }
      after_action { assiette_settle_etag! }
    end
  end
end
