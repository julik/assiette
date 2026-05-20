# frozen_string_literal: true

require_relative "lib/assiette/version"

Gem::Specification.new do |spec|
  spec.name = "assiette"
  spec.version = Assiette::VERSION
  spec.authors = ["Julik Tarkhanov"]
  spec.email = ["me@julik.nl"]

  spec.summary = "Zero-build asset serving for Rails engines"
  spec.description = "Serves static assets with cache-busting version tags and on-the-fly JS/CSS URL rewriting, without requiring any asset pipeline"
  spec.homepage = "https://github.com/julik/assiette"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,lib}/**/*", "LICENSE.txt", "Rakefile"]
  end

  spec.add_dependency "railties", ">= 7.2"
  spec.add_dependency "actionpack", ">= 7.2"
end
