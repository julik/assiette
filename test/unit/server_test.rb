# frozen_string_literal: true

require "test_helper"

class ServerTest < ActiveSupport::TestCase
  setup do
    @assets = build_handler(assets_root)
    @public = build_handler(public_root)
    @app = ->(env) { [404, {"content-type" => "text/plain"}, ["passed through"]] }
  end

  test "a plain handler serves assets" do
    server = Assiette::Server.new(@app, @assets)
    status, headers, body = server.call(env_for("/application.css"))

    assert_equal 200, status
    assert_equal "text/css", headers["content-type"]
    assert_includes body.first, "box-sizing"
  end

  test "keyword arguments still build a handler" do
    server = Assiette::Server.new(@app, root: assets_root)
    status, _, _ = server.call(env_for("/application.css"))

    assert_equal 200, status
  end

  test "a callable returning a handler serves assets" do
    server = Assiette::Server.new(@app, ->(_env) { @assets })
    status, headers, body = server.call(env_for("/application.css"))

    assert_equal 200, status
    assert_equal "text/css", headers["content-type"]
    assert_includes body.first, "box-sizing"
  end

  test "the callable is given the Rack env and may pick a handler from it" do
    by_host = ->(env) { (env["HTTP_HOST"] == "assets.example.com") ? @assets : @public }
    server = Assiette::Server.new(@app, by_host)

    status, headers, _ = server.call(env_for("/logo.png", "HTTP_HOST" => "images.example.com"))
    assert_equal 200, status
    assert_equal "image/png", headers["content-type"]

    status, _, _ = server.call(env_for("/logo.png", "HTTP_HOST" => "assets.example.com"))
    assert_equal 404, status, "the handler picked for this host does not hold logo.png"
  end

  test "the callable is resolved once per request" do
    calls = 0
    server = Assiette::Server.new(@app, ->(_env) {
      calls += 1
      @assets
    })

    server.call(env_for("/application.css"))
    assert_equal 1, calls

    server.call(env_for("/application.css"))
    assert_equal 2, calls
  end

  test "a callable returning nil passes the request through" do
    server = Assiette::Server.new(@app, ->(_env) {})
    status, _, body = server.call(env_for("/application.css"))

    assert_equal 404, status
    assert_equal ["passed through"], body
  end

  test "a callable returning nil leaves assiette.stack untouched" do
    env = env_for("/application.css")
    Assiette::Server.new(@app, ->(_env) {}).call(env)

    assert_not env.key?("assiette.stack"),
      "a Server with nothing to serve must not announce itself to the view helpers"
  end

  test "a callable returning nil leaves an outer Server's stack entry alone" do
    env = env_for("/application.css")
    inner = Assiette::Server.new(@app, ->(_env) {})
    Assiette::Server.new(inner, @public).call(env)

    assert_equal [@public], env["assiette.stack"].map { |entry| entry[:handler] }
  end

  test "the resolved handler and the SCRIPT_NAME land on the stack" do
    env = env_for("/nonexistent.css", "SCRIPT_NAME" => "/mounted")
    Assiette::Server.new(@app, ->(_env) { @assets }).call(env)

    assert_equal [{handler: @assets, script_name: "/mounted"}], env["assiette.stack"]
  end

  test "stacked Servers push an entry each, innermost last" do
    env = env_for("/nonexistent.css")
    inner = Assiette::Server.new(@app, @assets)
    Assiette::Server.new(inner, @public).call(env)

    assert_equal [@public, @assets], env["assiette.stack"].map { |entry| entry[:handler] }
  end

  private

  def assets_root
    File.expand_path("../dummy/app/assets", __dir__)
  end

  def public_root
    File.expand_path("../dummy/public", __dir__)
  end

  def build_handler(root)
    Assiette::AssetHandler.new(root: root)
  end

  def env_for(path, extra = {})
    {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => path,
      "SCRIPT_NAME" => "",
      "rack.input" => StringIO.new
    }.merge(extra)
  end
end
