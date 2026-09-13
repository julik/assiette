# frozen_string_literal: true

module Assiette
  class Server
    CACHE_CONTROL = "public, max-age=432000, must-revalidate"

    # Accepts a pre-built handler, something callable returning a handler for
    # the request at hand, or keyword args:
    #   Server.new(app, handler)
    #   Server.new(app, ->(env) { Tenant.for(env)&.assiette_handler })
    #   Server.new(app, root: "...", additional_directory_mappings: {})
    #
    # The callable form is for applications whose served locations vary per
    # request — a multi-tenant app hands every tenant its own AssetHandler
    # rooted in that tenant's directory. It is called once per request with the
    # Rack env and may return nil, meaning "nothing to serve here": the request
    # then passes straight through, with no entry added to the handler stack.
    def initialize(app, handler = nil, root: nil, additional_directory_mappings: {})
      @app = app
      @handler = handler || AssetHandler.new(root: root, additional_directory_mappings: additional_directory_mappings)
    end

    def call(env)
      handler = resolve_handler(env)
      return @app.call(env) unless handler

      stack = (env["assiette.stack"] ||= [])
      stack << {handler: handler, script_name: env["SCRIPT_NAME"].to_s}

      result = serve(env, handler)
      return result if result

      @app.call(env)
    end

    private

    def resolve_handler(env)
      @handler.respond_to?(:call) ? @handler.call(env) : @handler
    end

    def serve(env, handler)
      return unless env["REQUEST_METHOD"] == "GET" || env["REQUEST_METHOD"] == "HEAD"

      path_info = Rack::Utils.unescape_path(env["PATH_INFO"])
      path_info = path_info.sub(%r{\A/}, "")

      extension = File.extname(path_info)
      content_type = AssetHandler::CONTENT_TYPES[extension]
      return unless content_type

      file_path = handler.resolve_file(path_info)
      return unless file_path

      # Use the dependency graph's content hash for the ETag — it reflects
      # the file's own content plus all its transitive dependencies, and is
      # already computed as part of serving. This lets us short-circuit with
      # a 304 before reading the file for rewriting.
      etag = %("#{handler.dependency_graph.tree_sha(path_info) || "0"}")
      if env["HTTP_IF_NONE_MATCH"] == etag
        return [304, {"etag" => etag, "cache-control" => CACHE_CONTROL}, []]
      end

      raw_bytes = File.binread(file_path)
      body = handler.dependency_graph.rewrite_content(path_info, raw_bytes)

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
