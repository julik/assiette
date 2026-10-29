# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/assiette/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests Assiette::Generators::InstallGenerator
  destination File.expand_path("../tmp", __dir__)

  setup do
    prepare_destination
  end

  test "creates assiette initializer" do
    run_generator

    assert_file "config/initializers/assiette.rb" do |content|
      assert_match(/Assiette::Server/, content)
      assert_match(/app\/assets/, content)
      assert_match(/public/, content)
    end
  end
end
