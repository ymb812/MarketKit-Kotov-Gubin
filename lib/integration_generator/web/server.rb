# frozen_string_literal: true

require "json"
require "webrick"
require_relative "application"

module IntegrationGenerator
  module Web
    class Server
      STATIC_FILES = { "/" => ["index.html", "text/html; charset=utf-8"], "/app.css" => ["app.css", "text/css; charset=utf-8"], "/app.js" => ["app.js", "application/javascript; charset=utf-8"] }.freeze

      def initialize(root: File.expand_path("../../..", __dir__), port: 9292, application: nil)
        @root = root
        @port = port
        @application = application || Application.new(root: root)
      end

      def start
        server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: @port, AccessLog: [], Logger: WEBrick::Log.new(File::NULL))
        server.mount_proc("/") { |request, response| handle(request, response) }
        trap("INT") { server.shutdown }
        trap("TERM") { server.shutdown }
        puts "Payout Studio: http://127.0.0.1:#{@port} (Ctrl+C to stop)"
        server.start
      end

      def handle(request, response)
        return json_error(response, 403, "WEB_FORBIDDEN", "Only localhost hosts are accepted") unless allowed_host?(request)
        return json_error(response, 403, "WEB_FORBIDDEN", "Cross-origin requests are not accepted") unless allowed_origin?(request)

        case [request.request_method, request.path]
        when ["GET", "/api/examples"] then json(response, 200, "examples" => @application.examples)
        when ["POST", "/api/analyze"] then api_post(request, response) { |input| @application.analyze(input) }
        when ["POST", "/api/generate"] then api_post(request, response) { |input| @application.generate(input) }
        else
          static(request, response)
        end
      rescue IntegrationGenerator::Error => e
        json_error(response, client_error_status(e), e.code, e.message, e.location)
      rescue JSON::ParserError => e
        json_error(response, 400, "WEB_INVALID_JSON", e.message)
      rescue StandardError
        json_error(response, 500, "WEB_INTERNAL_ERROR", "Unexpected local server error")
      end

      private

      def api_post(request, response)
        return json_error(response, 415, "WEB_UNSUPPORTED_MEDIA_TYPE", "Expected application/json") unless request["content-type"].to_s.downcase.start_with?("application/json")
        return json_error(response, 413, "WEB_REQUEST_TOO_LARGE", "Request body exceeds #{Application::MAX_BODY_BYTES} bytes") if request.content_length.to_i > Application::MAX_BODY_BYTES

        body = request.body.to_s
        return json_error(response, 413, "WEB_REQUEST_TOO_LARGE", "Request body exceeds #{Application::MAX_BODY_BYTES} bytes") if body.bytesize > Application::MAX_BODY_BYTES
        input = JSON.parse(body)
        return json_error(response, 400, "WEB_INVALID_REQUEST", "JSON request must be an object") unless input.is_a?(Hash)

        json(response, 200, yield(input))
      end

      def static(request, response)
        download = %r{\A/api/download/(web-[0-9a-f]{16})/([a-zA-Z0-9][a-zA-Z0-9_.-]*)\z}.match(request.path)
        if request.request_method == "GET" && download
          response.body = @application.download(download[1], download[2])
          response.status = 200
          response["Content-Type"] = download[2].end_with?(".tar.gz") ? "application/gzip" : "application/octet-stream"
          response["Content-Disposition"] = "attachment; filename=\"#{download[2]}\""
          response["X-Content-Type-Options"] = "nosniff"
          return
        end
        return json_error(response, 404, "WEB_NOT_FOUND", "Route was not found") unless request.request_method == "GET" && STATIC_FILES.key?(request.path)

        filename, content_type = STATIC_FILES.fetch(request.path)
        path = File.join(@root, "web", filename)
        return json_error(response, 404, "WEB_NOT_FOUND", "Static asset was not found") unless File.file?(path)

        response.status = 200
        response["Content-Type"] = content_type
        response.body = File.binread(path)
      end

      def allowed_host?(request)
        host = request.host.to_s.downcase
        %w[localhost 127.0.0.1].include?(host)
      end

      def allowed_origin?(request)
        origin = request["origin"]
        return true if origin.nil? || origin.empty?

        expected = "http://#{request.host.downcase}"
        expected += ":#{@port}" unless @port == 80
        origin.downcase == expected
      end

      def client_error_status(error)
        return 404 if error.code == "WEB_NOT_FOUND"
        return 413 if error.code == "WEB_REQUEST_TOO_LARGE"
        return 400 if error.code.start_with?("WEB_") || error.code.include?("PARSE") || error.code.include?("INVALID") || error.code.include?("FORMAT")

        422
      end

      def json(response, status, body)
        response.status = status
        response["Content-Type"] = "application/json; charset=utf-8"
        response.body = JSON.generate(body)
      end

      def json_error(response, status, code, message, location = nil)
        error = IntegrationGenerator::DiagnosticRemediation.for_error(code, message, location)
        json(response, status, "error" => error)
      end
    end
  end
end
