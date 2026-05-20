# frozen_string_literal: true

require "rails/railtie"

module Assiette
  class Railtie < ::Rails::Railtie
    generators do
      require_relative "../generators/assiette/install/install_generator"
    end
  end
end
