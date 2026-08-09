# frozen_string_literal: true

# Uses the macro the railtie installs on ActionController::Base.
class EtagController < ActionController::Base
  include_assiette_etags!

  def show
    fresh_when(etag: "fixed")
    render plain: "etagged" unless performed?
  end
end

# Same action, same validator, no Assiette digest folded in.
class PlainEtagController < ActionController::Base
  def show
    fresh_when(etag: "fixed")
    render plain: "etagged" unless performed?
  end
end
