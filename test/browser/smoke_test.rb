# frozen_string_literal: true

require "test_helper"
require "ferrum"
require "rackup"

class BrowserSmokeTest < ActionDispatch::IntegrationTest
  setup do
    # Find a free port
    server = TCPServer.new("127.0.0.1", 0)
    @port = server.addr[1]
    server.close

    @server_thread = Thread.new do
      Rackup::Handler::WEBrick.run(Rails.application,
        Port: @port, Logger: Logger.new(File::NULL), AccessLog: [])
    end

    # Wait for the server to accept connections
    deadline = Time.now + 5
    loop do
      TCPSocket.new("127.0.0.1", @port).close
      break
    rescue Errno::ECONNREFUSED
      raise "Server did not start in time" if Time.now > deadline
      sleep 0.05
    end

    @browser = Ferrum::Browser.new(headless: true, js_errors: false)
    @console = []
    @errors = []

    @browser.on("Runtime.consoleAPICalled") do |params|
      text = params["args"].map { |a| a["value"] || a["description"] || a.to_s }.join(" ")
      if params["type"] == "error"
        @errors << text
      else
        @console << text
      end
    end

    @browser.on("Runtime.exceptionThrown") do |params|
      @errors << params.dig("exceptionDetails", "text")
    end
  end

  teardown do
    @browser&.quit
    @server_thread&.kill
  end

  test "page loads CSS, modulepreload tags, and executes JS module graph" do
    @browser.goto("http://127.0.0.1:#{@port}/smoke")

    # The page should have rendered
    assert_equal "Smoke", @browser.at_css("h1")&.text

    # CSS should have loaded — check that box-sizing was applied
    box_sizing = @browser.evaluate("getComputedStyle(document.body).boxSizing")
    assert_equal "border-box", box_sizing

    # The module graph should have executed: root_a.js logs to console
    match = @console.find { |m| m.start_with?("root_a:") }
    assert match, "Expected root_a.js console.log, got: #{@console.inspect}"
    assert_equal 'root_a:[["a1","a2"],["b1","b2"],["g1","g2"]]', match

    # The module should have written its status into the DOM
    status = @browser.at_css("#js-status")&.text
    assert_includes status, '["a1","a2"]'

    # No JS errors should have occurred
    assert_empty @errors, "Expected no JS errors"
  end
end
