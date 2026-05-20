# frozen_string_literal: true

class SmokeController < ActionController::Base
  def index
    render layout: false
  end
end
