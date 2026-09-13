# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", require: false
gem "railties", ">= 7.2", require: false
gem "standardrb", "~> 1.0", require: false
gem "ferrum", require: false
# Needed by the browser smoke test, which boots the dummy app under WEBrick.
# Neither is a transitive dependency we can rely on: ferrum dropped its webrick
# dependency in 0.18.0, and rackup only reaches us via railties.
gem "rackup", require: false
gem "webrick", require: false
