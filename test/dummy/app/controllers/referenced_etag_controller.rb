# frozen_string_literal: true

# Two pages behind the same validator, each linking a different asset. With
# `digest: :referenced` their ETags must differ, because the pages link
# different things — under the apex digest both would fold in the same hash.
class ReferencedEtagController < ActionController::Base
  include_assiette_etags!

  def css_page
    fresh_when(etag: "fixed")
  end

  def image_page
    fresh_when(etag: "fixed")
  end

  # Links one entry module, which imports a tree of others.
  def js_page
    fresh_when(etag: "fixed")
  end

  # Renders a listing of every module the handler holds, rather than naming
  # links — so it depends on which files exist.
  def preload_page
    fresh_when(etag: "fixed")
  end
end
