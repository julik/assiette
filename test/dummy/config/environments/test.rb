# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_dispatch.show_exceptions = :rescuable

  # Pin the secret instead of letting Rails generate tmp/local_secret.txt on
  # demand: the parallel test workers boot with a cold tmp/ and race each
  # other, and a worker that reads the file mid-write gets an empty string.
  config.secret_key_base = "assiette_dummy_app_secret_key_base"
end
