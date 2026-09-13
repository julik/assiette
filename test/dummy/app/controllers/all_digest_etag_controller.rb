# frozen_string_literal: true

# The same page as ReferencedEtagController#css_page, folding in the
# whole-handler digest instead of the page's own links.
class AllDigestEtagController < ActionController::Base
  include_assiette_etags!(digest: :all)

  def css_page
    fresh_when(etag: "fixed")
    render "referenced_etag/css_page" unless performed?
  end
end
