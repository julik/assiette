# frozen_string_literal: true

module Assiette
  class Server
    CACHE_CONTROL = "public, max-age=432000, must-revalidate"

    # Accepts either a pre-built handler or keyword args:
    #   Server.new(app, handler)
    #   Server.new(app, root: "...", additional_directory_mappings: {})
    def initialize(app, handler = nil, root: nil, additional_directory_mappings: {})
      @app = app
      @handler = handler || AssetHandler.new(root: root, additional_directory_mappings: additional_directory_mappings)
    end

    def call(env)
      stack = (env["assiette.stack"] ||= [])
      stack << {handler: @handler, script_name: env["SCRIPT_NAME"].to_s}

      result = serve(env)
      return result if result

      @app.call(env)
    end

    private

    def serve(env)
      return unless env["REQUEST_METHOD"] == "GET" || env["REQUEST_METHOD"] == "HEAD"

      path_info = Rack::Utils.unescape_path(env["PATH_INFO"])
      path_info = path_info.sub(%r{\A/}, "")

      extension = File.extname(path_info)
      content_type = AssetHandler::CONTENT_TYPES[extension]
      return unless content_type

      file_path = @handler.resolve_file(path_info)
      return unless file_path

      # Use the dependency graph's content hash for the ETag — it reflects
      # the file's own content plus all its transitive dependencies, and is
      # already computed as part of serving. This lets us short-circuit with
      # a 304 before reading the file for rewriting.
      etag = %("#{@handler.dependency_graph.tree_sha(path_info) || "0"}")
      if env["HTTP_IF_NONE_MATCH"] == etag
        return [304, {"etag" => etag, "cache-control" => CACHE_CONTROL}, []]
      end

      raw_bytes = File.binread(file_path)
      body = @handler.dependency_graph.rewrite_content(path_info, raw_bytes)

      headers = {
        "content-type" => content_type,
        "content-length" => body.bytesize.to_s,
        "cache-control" => CACHE_CONTROL,
        "etag" => etag
      }

      [200, headers, [body]]
    end
  end
end
