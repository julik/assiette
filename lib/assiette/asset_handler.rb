# frozen_string_literal: true

require "digest/sha1"
require "digest/sha2"
require "base64"
require "pathname"
require_relative "rewriter"
require_relative "version_tag"

module Assiette
  class AssetHandler
    CONTENT_TYPES = {
      ".js" => "application/javascript",
      ".mjs" => "application/javascript",
      ".css" => "text/css",
      ".svg" => "image/svg+xml",
      ".png" => "image/png",
      ".ico" => "image/x-icon"
    }.freeze

    JS_EXTENSIONS = %w[.js .mjs].to_set.freeze

    def initialize(root:, additional_directory_mappings: {})
      @mappings = build_mappings(root, additional_directory_mappings)
      @integrity_cache = {}
      @integrity_mutex = Mutex.new
      @modules_cache = nil
      @modules_mutex = Mutex.new
      @modules_version = nil
    end

    def resolve_file(path)
      clean = path.sub(%r{\A/}, "")
      @mappings.each do |prefix, root|
        if prefix.empty?
          relative = clean
        elsif clean.start_with?(prefix + "/")
          relative = clean[(prefix.length + 1)..]
        elsif clean == prefix
          next
        else
          next
        end

        abs = root.join(relative).cleanpath
        next unless abs.to_s.start_with?(root.to_s + "/")
        return abs if abs.exist? && abs.file?
      end
      nil
    end

    def absolute_asset_url_path(path, script_name = "")
      clean = path.sub(%r{\A/}, "")
      return nil unless resolve_file(clean)
      "#{script_name}/#{clean}?v=#{Assiette.version_tag}"
    end

    def asset_integrity(path)
      version_tag = Assiette.version_tag
      @integrity_mutex.synchronize do
        if @integrity_version != version_tag
          @integrity_cache = {}
          @integrity_version = version_tag
        end
        return @integrity_cache[path] if @integrity_cache.key?(path)

        clean = path.sub(%r{\A/}, "")
        @integrity_cache[path] = compute_integrity(clean, version_tag)
      end
    end

    def js_modules
      version_tag = Assiette.version_tag
      @modules_mutex.synchronize do
        return @modules_cache if @modules_version == version_tag

        @modules_cache = @mappings.flat_map { |prefix, root|
          Dir[File.join(root, "**/*.{js,mjs}")].filter_map { |abs|
            next unless File.foreach(abs).any? { |line| line.match?(/\A\s*(import|export)\s/) }
            relative = Pathname.new(abs).relative_path_from(root).to_s
            mod_path = "/#{"#{prefix}/" unless prefix.empty?}#{relative}".squeeze("/")
            {path: mod_path, integrity: asset_integrity(mod_path)}
          }
        }.uniq { |m| m[:path] }.sort_by { |m| m[:path] }

        @modules_version = version_tag
        @modules_cache
      end
    end

    private

    def build_mappings(root, additional_directory_mappings)
      mappings = [["", Pathname.new(root).expand_path]]
      additional_directory_mappings.each do |prefix, path|
        clean_prefix = prefix.to_s.sub(%r{\A/}, "").chomp("/")
        mappings << [clean_prefix, Pathname.new(path).expand_path]
      end
      mappings
    end

    def compute_integrity(clean, version_tag)
      file_path = resolve_file(clean)
      return nil unless file_path

      raw = File.read(file_path)
      ext = File.extname(clean)
      served = case ext
      when ".js", ".mjs" then Rewriter.rewrite_js_imports(raw, version_tag)
      when ".css" then Rewriter.rewrite_css_urls(raw, version_tag)
      else raw
      end
      "sha256-#{Base64.strict_encode64(Digest::SHA256.digest(served))}"
    end
  end
end
