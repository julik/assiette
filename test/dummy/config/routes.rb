# frozen_string_literal: true

Rails.application.routes.draw do
  get "smoke", to: "smoke#index"
  get "etagged", to: "etag#show"
  get "plain_etagged", to: "plain_etag#show"
  get "referenced/css", to: "referenced_etag#css_page"
  get "referenced/image", to: "referenced_etag#image_page"
  get "all_digest/css", to: "all_digest_etag#css_page"
end
