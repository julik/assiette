# frozen_string_literal: true

require_relative "assiette/version"
require_relative "assiette/version_tag"
require_relative "assiette/rewriter"
require_relative "assiette/server"
require_relative "assiette/helpers"
require_relative "assiette/railtie" if defined?(Rails::Railtie)

module Assiette
end
