# frozen_string_literal: true

Rails.application.routes.draw do
  get "smoke", to: "smoke#index"
  get "etagged", to: "etag#show"
  get "plain_etagged", to: "plain_etag#show"
end
