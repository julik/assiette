# frozen_string_literal: true

module Assiette
  # Remembers which assets a page referenced the last time it was rendered.
  #
  # This exists because of an ordering problem. Rails evaluates `etag` blocks
  # inside `fresh_when`, in the action — before the template renders. So at the
  # moment a page's validator is built, nobody knows yet which assets that page
  # is about to link. The set from the previous render is the best available
  # answer, and it is a good one: which assets a page links changes when the
  # template does, which is a deploy, which empties this log anyway.
  #
  # Keys are request signatures (see ControllerEtag), values are sorted arrays
  # of URL paths. Bounded and insertion-ordered — once it is full the oldest
  # entry goes, which for a per-process cache of "pages this worker rendered"
  # is a reasonable eviction order.
  class ReferenceLog
    DEFAULT_LIMIT = 2048

    attr_reader :limit

    def initialize(limit: DEFAULT_LIMIT)
      @limit = limit
      @mutex = Mutex.new
      @entries = {}
    end

    # The paths remembered for a key, or nil if this process has not rendered
    # that page yet. nil and [] mean different things: nil is "no idea", and
    # the caller falls back to the whole-handler digest, while [] is "rendered,
    # linked nothing" and is a perfectly good answer.
    def [](key)
      @mutex.synchronize { @entries[key] }
    end

    def record(key, url_paths)
      paths = url_paths.to_a.sort.freeze
      @mutex.synchronize do
        @entries.delete(key) # re-insert so a page in active use stays young
        @entries[key] = paths
        @entries.shift while @entries.size > @limit
      end
      paths
    end

    def size
      @mutex.synchronize { @entries.size }
    end

    def clear
      @mutex.synchronize { @entries.clear }
    end
  end
end
