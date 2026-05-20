# frozen_string_literal: true

Rails.application.routes.draw do
  get "smoke", to: "smoke#index"
end
