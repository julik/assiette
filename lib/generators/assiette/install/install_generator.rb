# frozen_string_literal: true

require "rails/generators"

module Assiette
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates an Assiette initializer with middleware configuration"

      def create_initializer
        template "initializer.rb.tt", "config/initializers/assiette.rb"
      end
    end
  end
end
