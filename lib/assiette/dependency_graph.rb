# frozen_string_literal: true

require "tsort"
require "digest/sha2"
require "base64"
require "pathname"
require "set"

module Assiette
  class DependencyGraph
    # Per-file node in the dependency graph.
    class Asset
      attr_reader :url_path
      attr_accessor :abs_path, :mtime, :digest, :deps, :dependents

      def initialize(url_path:, abs_path:, mtime:)
        @url_path = url_path.freeze
        @abs_path = abs_path
        @mtime = mtime
        @digest = nil
        @deps = []
        @dependents = Set.new
      end

      # 8-char hex hash for ?s= cache-busting query params.
      def checksum_tag
        digest&.unpack1("H8")
      end

      # SRI integrity string for integrity= attributes.
      def sri_integrity
        return nil unless digest
        "sha256-#{Base64.strict_encode64(digest)}"
      end

      # Whether this asset's file has changed since last scan.
      def stale?
        File.mtime(abs_path) != mtime
      rescue Errno::ENOENT
        true
      end

      # Whether the file no longer exists on disk.
      def deleted?
        !File.exist?(abs_path.to_s)
      end
    end

    def initialize(handler)
      @handler = handler
      @mutex = Mutex.new
      @assets = nil # url_path -> Asset, nil means not yet built
    end

    # Returns the Asset for a url_path, or nil.
    def [](url_path)
      @mutex.synchronize do
        ensure_built!
        refresh_stale!
        @assets[url_path]
      end
    end

    # Returns the 8-char hex content hash for a URL path.
    def tree_sha(url_path)
      self[url_path]&.checksum_tag
    end

    # Returns the SRI integrity string for a URL path.
    def tree_integrity(url_path)
      self[url_path]&.sri_integrity
    end

    # Resolves a relative import path to a URL path.
    def resolve_import_for(from_url_path, relative_path)
      if relative_path.start_with?("/")
        relative_path.sub(%r{\A/}, "")
      else
        dir = File.dirname(from_url_path)
        File.expand_path(relative_path, "/#{dir}").sub(%r{\A/}, "")
      end
    end

    # Rewrites content with per-dependency hashes. Thread-safe.
    def rewrite_content(url_path, raw_content)
      @mutex.synchronize do
        ensure_built!
        refresh_stale!
        rewrite_content_internal(url_path, raw_content)
      end
    end

    # Forces a full rebuild on next access.
    def invalidate!
      @mutex.synchronize do
        @assets = nil
      end
    end

    private

    def ensure_built!
      return if @assets

      @assets = {}

      # First pass: create all Asset nodes and parse imports
      @handler.each_mapped_file do |url_path, abs_path|
        asset = @assets[url_path] = Asset.new(
          url_path: url_path,
          abs_path: abs_path,
          mtime: File.mtime(abs_path)
        )
        asset.deps = parse_deps(url_path, File.read(abs_path))
      end

      # Second pass: build reverse dependency links
      @assets.each_value do |asset|
        asset.deps.each do |dep_path|
          dep = @assets[dep_path]
          dep.dependents << asset.url_path if dep
        end
      end

      compute_all_digests!
    end

    def parse_deps(url_path, raw)
      ext = File.extname(url_path)
      import_paths = case ext
      when ".js", ".mjs", ".es" then Rewriter.extract_js_imports(raw)
      when ".css" then Rewriter.extract_css_urls(raw)
      else []
      end
      import_paths.map { |p| resolve_import_for(url_path, p) }
    end

    def compute_all_digests!
      each_node = ->(& b) { @assets.each_key(&b) }
      each_child = ->(node, &b) { (@assets[node]&.deps || []).each(&b) }

      TSort.each_strongly_connected_component(each_node, each_child) do |scc|
        if scc.size == 1
          compute_digest_for(scc[0])
        else
          compute_cycle_digests(scc)
        end
      end
    end

    def compute_digest_for(url_path)
      asset = @assets[url_path]
      return unless asset

      raw = File.read(asset.abs_path)
      if asset.deps.empty?
        asset.digest = Digest::SHA256.digest(raw)
      else
        rewritten = rewrite_content_internal(url_path, raw)
        asset.digest = Digest::SHA256.digest(rewritten)
      end
    end

    # For cyclic dependencies: hash all members' raw contents together.
    # All cycle members get the same digest, which changes when any member changes.
    def compute_cycle_digests(scc)
      combined = scc.sort.filter_map { |url_path|
        asset = @assets[url_path]
        next unless asset
        File.read(asset.abs_path)
      }.join("\0")

      digest = Digest::SHA256.digest(combined)
      scc.each do |url_path|
        asset = @assets[url_path]
        asset.digest = digest if asset
      end
    end

    # Rewrites content without acquiring the mutex (called within synchronized blocks).
    def rewrite_content_internal(url_path, raw_content)
      ext = File.extname(url_path)
      case ext
      when ".js", ".mjs", ".es"
        Rewriter.rewrite_js_imports(raw_content) do |import_path|
          resolved = resolve_import_for(url_path, import_path)
          @assets[resolved]&.checksum_tag || "00000000"
        end
      when ".css"
        Rewriter.rewrite_css_urls(raw_content) do |ref_path|
          resolved = resolve_import_for(url_path, ref_path)
          @assets[resolved]&.checksum_tag || "00000000"
        end
      else
        raw_content
      end
    end

    def refresh_stale!
      stale = []
      deleted = []

      @assets.each_value do |asset|
        if asset.deleted?
          deleted << asset.url_path
        elsif asset.stale?
          stale << asset.url_path
        end
      end

      return if stale.empty? && deleted.empty?

      # Collect transitive ancestors BEFORE removing deleted nodes
      to_recompute = Set.new(stale)
      queue = (stale + deleted).dup
      until queue.empty?
        node = queue.shift
        asset = @assets[node]
        next unless asset
        asset.dependents.each do |ancestor|
          if to_recompute.add?(ancestor)
            queue << ancestor
          end
        end
      end

      # Remove deleted files from the graph
      deleted.each { |url_path| remove_asset!(url_path) }

      # Re-scan stale files
      stale.each { |url_path| rescan_asset!(url_path) }

      # Recompute digests in dependency order for affected nodes
      each_node = ->(& b) { @assets.each_key(&b) }
      each_child = ->(node, &b) { (@assets[node]&.deps || []).each(&b) }

      TSort.each_strongly_connected_component(each_node, each_child) do |scc|
        if scc.size == 1
          compute_digest_for(scc[0]) if to_recompute.include?(scc[0])
        else
          compute_cycle_digests(scc) if scc.any? { |n| to_recompute.include?(n) }
        end
      end
    end

    def remove_asset!(url_path)
      asset = @assets.delete(url_path)
      return unless asset

      # Remove from deps' dependent lists
      asset.deps.each do |dep_path|
        dep = @assets[dep_path]
        dep.dependents.delete(url_path) if dep
      end
    end

    def rescan_asset!(url_path)
      asset = @assets[url_path]
      return unless asset

      asset.mtime = File.mtime(asset.abs_path)

      # Remove old reverse links
      asset.deps.each do |dep_path|
        dep = @assets[dep_path]
        dep.dependents.delete(url_path) if dep
      end

      # Re-parse imports
      raw = File.read(asset.abs_path)
      asset.deps = parse_deps(url_path, raw)

      # Re-establish reverse links
      asset.deps.each do |dep_path|
        dep = @assets[dep_path]
        dep.dependents << url_path if dep
      end
    end
  end
end
