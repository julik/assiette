# frozen_string_literal: true

require "pathname"
require "digest/sha2"

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

    # A single 16-char hex hash covering every asset this handler can serve.
    # Fold it into a page's ETag and the page stops validating as soon as any
    # Assiette URL on it would come out different.
    #
    # This is not a sweep over every mapped file — it hashes the dependency
    # graph's apexes, whose digests already fold in everything they reach.
    def digest
      ensure_graph_populated!
      combined = Digest::SHA256.new
      @dependency_graph.apex_paths.each do |url_path|
        combined << url_path << "\0" << @dependency_graph.tree_sha(url_path).to_s << "\0"
      end
      combined.hexdigest[0, 16]
    end

    private

    # The apex set is only meaningful over a fully populated graph, and the
    # graph is lazy — asking it opportunistically gives different answers
    # depending on what has been requested so far, which would have two Puma
    # workers computing different ETags for identical content.
    #
    # The walk is amortised behind a directory-mtime guard rather than a glob
    # per call. Directory mtimes move when an entry is added, removed or
    # renamed — exactly the events that change the file list. Editing a file in
    # place does not move them, and does not need to: the graph checks per-file
    # mtimes on every access.
    def ensure_graph_populated!
      return if walked_directories_unchanged?
      walked = {}
      each_mapped_file do |url_path, abs_path|
        @dependency_graph[url_path]
        dir = File.dirname(abs_path)
        walked[dir] ||= File.mtime(dir)
      end
      @dependency_graph.prune_deleted!
      @walked_directories = walked
    end

    def walked_directories_unchanged?
      return false unless @walked_directories
      @walked_directories.all? { |dir, mtime| File.mtime(dir) == mtime }
    rescue Errno::ENOENT
      false
    end

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
