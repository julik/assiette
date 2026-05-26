# frozen_string_literal: true

require "pathname"

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

    attr_reader :dependency_graph

    def initialize(root:, additional_directory_mappings: {})
      @mappings = build_mappings(root, additional_directory_mappings)
      @dependency_graph = DependencyGraph.new(self)
    end

    # Yields (url_path, abs_path) for every file with a recognized extension.
    def each_mapped_file
      @mappings.each do |prefix, root|
        CONTENT_TYPES.each_key do |ext|
          Dir[File.join(root, "**/*#{ext}")].each do |abs|
            relative = Pathname.new(abs).relative_path_from(root).to_s
            url_path = if prefix.empty?
              relative
            else
              "#{prefix}/#{relative}"
            end
            yield url_path, abs
          end
        end
      end
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
      hash = @dependency_graph.tree_sha(clean) || "00000000"
      "#{script_name}/#{clean}?s=#{hash}"
    end

    def asset_integrity(path)
      clean = path.sub(%r{\A/}, "")
      return nil unless resolve_file(clean)
      @dependency_graph.tree_integrity(clean)
    end

    def js_modules
      @mappings.flat_map { |prefix, root|
        Dir[File.join(root, "**/*.{js,mjs}")].filter_map { |abs|
          next unless File.foreach(abs).any? { |line| line.match?(/\A\s*(import|export)\s/) }
          relative = Pathname.new(abs).relative_path_from(root).to_s
          mod_path = "/#{"#{prefix}/" unless prefix.empty?}#{relative}".squeeze("/")
          {path: mod_path, integrity: asset_integrity(mod_path)}
        }
      }.uniq { |m| m[:path] }.sort_by { |m| m[:path] }
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
  end
end
