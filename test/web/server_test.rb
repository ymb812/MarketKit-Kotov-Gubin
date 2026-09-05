# frozen_string_literal: true

require_relative "../test_helper"
require "integration_generator/web/server"

class WebServerTest < Minitest::Test
  Request = Struct.new(:request_method, :path, :host, :headers, :body, :content_length, keyword_init: true) do
    def [](key)
      headers[key]
    end
  end

  Response = Struct.new(:status, :headers, :body, keyword_init: true) do
    def []=(key, value)
      self.headers[key] = value
    end
  end

  def test_rejects_non_local_host_and_cross_origin_api_requests
    response = call(request(method: "GET", path: "/api/examples", host: "evil.example"))
    assert_equal 403, response.status
    assert_equal "WEB_FORBIDDEN", JSON.parse(response.body).dig("error", "code")

    response = call(request(method: "GET", path: "/api/examples", headers: { "origin" => "https://evil.example" }))
    assert_equal 403, response.status
    assert_equal "WEB_FORBIDDEN", JSON.parse(response.body).dig("error", "code")
  end

  def test_api_requires_json_and_static_routes_are_allowlisted
    response = call(request(method: "POST", path: "/api/analyze", headers: { "content-type" => "text/plain" }, body: "{}"))
    assert_equal 415, response.status

    response = call(request(method: "GET", path: "/../../Gemfile"))
    assert_equal 404, response.status
    assert_equal "WEB_NOT_FOUND", JSON.parse(response.body).dig("error", "code")
  end

  def test_origin_must_match_the_local_host_and_port
    response = call(request(method: "GET", path: "/api/examples", headers: { "origin" => "http://127.0.0.1:9292" }))
    assert_equal 200, response.status

    ["http://127.0.0.1:3000", "http://localhost:9292", "null"].each do |origin|
      response = call(request(method: "GET", path: "/api/examples", headers: { "origin" => origin }))
      assert_equal 403, response.status
    end
  end

  private

  def server
    @server ||= IntegrationGenerator::Web::Server.new(root: TestPaths::ROOT)
  end

  def call(request)
    response = Response.new(headers: {})
    server.handle(request, response)
    response
  end

  def request(method:, path:, host: "127.0.0.1", headers: {}, body: "")
    Request.new(request_method: method, path: path, host: host, headers: headers, body: body, content_length: body.bytesize)
  end
end
