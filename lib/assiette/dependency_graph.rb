# frozen_string_literal: true

require "digest/sha2"
require "base64"
require "pathname"

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
      @assets = {}
    end

    # Returns the Asset for a url_path, or nil.
    def [](url_path)
      @mutex.synchronize do
        ensure_asset!(url_path)
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
        ensure_asset!(url_path)
        rewrite_content_internal(url_path, raw_content)
      end
    end

    # Forces a full rebuild on next access.
    def invalidate!
      @mutex.synchronize do
        @assets = {}
      end
    end

    private

    # Lazily resolve a single asset and its transitive dependencies.
    # Returns the Asset or nil if the file doesn't exist.
    def ensure_asset!(url_path)
      @resolving = Set.new
      @checked = Set.new
      @cycle_groups = []
      asset = resolve_asset!(url_path)
      # Process any cycles detected during resolution
      @cycle_groups.each { |scc| compute_cycle_digests(scc) }
      @resolving = nil
      @checked = nil
      @cycle_groups = nil
      asset
    end

    # Recursive resolution. Detects cycles via @resolving set.
    # @checked prevents re-verifying the same asset within one ensure_asset! call.
    # Returns the Asset or nil. Also returns whether anything changed downstream.
    def resolve_asset!(url_path)
      # Already verified fresh in this ensure_asset! call
      return @assets[url_path] if @checked.include?(url_path)

      existing = @assets[url_path]
      if existing
        if existing.deleted?
          remove_asset!(url_path)
          return nil
        end

        if existing.stale?
          rescan_asset!(existing)
          @checked << url_path
          return existing
        end

        # Not stale itself — but deps might be. Check them recursively.
        @checked << url_path
        old_dep_digests = existing.deps.map { |dp| @assets[dp]&.digest }
        existing.deps.each { |dp| resolve_asset!(dp) }
        new_dep_digests = existing.deps.map { |dp| @assets[dp]&.digest }

        if old_dep_digests != new_dep_digests
          compute_digest_for(url_path)
        end

        return existing
      end

      # Resolve url_path to an absolute path
      abs_path = @handler.resolve_file(url_path)
      return nil unless abs_path

      # Cycle detection
      unless @resolving.add?(url_path)
        return @assets[url_path]
      end

      # Create the asset node
      asset = @assets[url_path] = Asset.new(
        url_path: url_path,
        abs_path: abs_path,
        mtime: File.mtime(abs_path)
      )
      asset.deps = parse_deps(url_path, File.read(abs_path))

      # Recursively resolve dependencies
      in_cycle = false
      asset.deps.each do |dep_path|
        if @resolving.include?(dep_path) && !@assets[dep_path]&.digest
          in_cycle = true
        end
        dep = resolve_asset!(dep_path)
        dep.dependents << url_path if dep
      end

      if in_cycle || asset.deps.any? { |dp| @resolving.include?(dp) && !@assets[dp]&.digest }
        scc = collect_cycle(url_path)
        @cycle_groups << scc unless scc.empty?
      else
        compute_digest_for(url_path)
      end

      @checked << url_path
      @resolving.delete(url_path)
      asset
    end

    # Collect strongly connected component members starting from url_path.
    def collect_cycle(url_path)
      visited = Set.new
      stack = [url_path]
      members = Set.new

      while (node = stack.pop)
        next unless visited.add?(node)
        asset = @assets[node]
        next unless asset
        members << node if @resolving.include?(node)
        asset.deps.each do |dep|
          stack << dep if @resolving.include?(dep)
        end
      end

      members.to_a
    end

    # Re-read a stale asset, re-parse deps, recursively ensure deps fresh, recompute digest.
    def rescan_asset!(asset)
      url_path = asset.url_path
      asset.mtime = File.mtime(asset.abs_path)

      # Remove old reverse links
      asset.deps.each do |dep_path|
        dep = @assets[dep_path]
        dep&.dependents&.delete(url_path)
      end

      # Re-parse imports
      raw = File.read(asset.abs_path)
      asset.deps = parse_deps(url_path, raw)

      # Recursively ensure deps are fresh
      asset.deps.each do |dep_path|
        dep = resolve_asset!(dep_path)
        dep.dependents << url_path if dep
      end

      # Recompute digest
      compute_digest_for(url_path)

      # Propagate to dependents already in the graph
      propagate_to_dependents!(asset)
    end

    # Recompute digests for all transitive dependents of an asset.
    def propagate_to_dependents!(asset)
      queue = asset.dependents.to_a
      visited = Set.new
      while (dep_url = queue.shift)
        next unless visited.add?(dep_url)
        dep_asset = @assets[dep_url]
        next unless dep_asset
        compute_digest_for(dep_url)
        queue.concat(dep_asset.dependents.to_a)
      end
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

    def remove_asset!(url_path)
      asset = @assets.delete(url_path)
      return unless asset

      asset.deps.each do |dep_path|
        dep = @assets[dep_path]
        dep&.dependents&.delete(url_path)
      end
    end
  end
end
