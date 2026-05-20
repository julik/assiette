# frozen_string_literal: true

require_relative "test_helper"
require "rackup"

server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
server.close

$stdout.sync = true
puts "Starting server on port #{port}..."

Thread.new do
  Rackup::Handler::WEBrick.run(Rails.application,
    Port: port, Logger: Logger.new(File::NULL), AccessLog: [])
end

deadline = Time.now + 5
loop do
  TCPSocket.new("127.0.0.1", port).close
  break
rescue Errno::ECONNREFUSED
  raise "Server did not start in time" if Time.now > deadline
  sleep 0.05
end

puts "Server running at http://127.0.0.1:#{port}/smoke"
puts "Press Ctrl+C to stop"
sleep
