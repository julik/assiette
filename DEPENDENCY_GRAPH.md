# The dependency graph

This is the detail behind the outline in [ARCHITECTURE.md](ARCHITECTURE.md#the-dependency-graph): how Assiette resolves imports, what a fingerprint actually covers, and how one hash over the whole graph is derived without sweeping your asset directories.

## Lazy resolution

The import rewriting is backed by a lazy dependency graph. It is not built at startup. The first time a file is requested, Assiette resolves its URL path to an absolute file path, reads it, extracts the imports, and then recursively does the same for each dependency. Digests are computed bottom-up: leaf files (with no imports of their own) get a straightforward SHA-256 of their raw content, and files with dependencies get a SHA-256 of their rewritten content, which already includes the hashes of everything they import. This means each file's fingerprint reflects the content of its entire dependency subtree.

Because the graph is lazy, files that nobody ever requests are never loaded into it. You can have a large asset directory with plenty of files that are only used in certain contexts, and only the ones that are actually served will be scanned. Staleness is checked per-file on each access using `File.mtime` — when a file changes on disk, the next request that touches it (or anything that depends on it) re-reads, re-parses, and recomputes digests up through all the dependents that are already in the graph.

Cyclic imports — the kind where `a.js` imports `b.js` and `b.js` imports `a.js` — are detected during the recursive resolution. When a cycle is found, all its members get the same digest, computed from their combined raw contents sorted by path. It is a pragmatic solution: the cycle is treated as a single unit, and changing any member causes all of them to bust. This matches what the browser actually does with circular ES module dependencies, so it works out fine in practice.

## Propagation

The invariant the graph exists to hold is that **a fingerprint never lags the bytes it stands for**. A node's served content is its raw content with every import rewritten to carry the fingerprint of the file it points at, and the node's own fingerprint is a hash of exactly those bytes. So the moment anything below a node changes, the node's served bytes change, and its fingerprint has to move with them or nobody refetches it.

Two paths lead there, and both have to propagate upward. A node whose own file is stale is re-read, re-parsed and recomputed, and then every transitive dependent already in the graph is recomputed too. A node that is *not* stale but whose dependencies turned out to have moved is recomputed as well — and it propagates for the same reason, because a dependent's freshness check compares its deps' digests from before and after its own visit, so a dep that was already updated during an earlier visit reads as unchanged. Without that second propagation, deleting `js/leaf/alpha_one.js` leaves `js/root_a.js` serving `./mid/alpha.js?s=<new>` under its old fingerprint, and every browser holding the old copy keeps it.

Propagation is also where a vanished importer gets noticed. Nothing resolves an importer from above — the graph only reaches it from below, through the files it imports — so a module that was deleted or renamed away is still sitting in its leaves' dependents. Recomputing it would mean reading a path that is not there, which is how a rename used to raise `Errno::ENOENT` out of a view helper on every render until a restart. Such a dependent is dropped instead, and its own dependents are still walked: they keep the vanished node in their deps until they are rescanned, and it rewrites to `00000000` now, so their fingerprints move.

## The apex digest

`AssetHandler#digest` is one hash covering every asset a handler can serve, so that a page linking Assiette URLs stops validating as soon as any of those URLs would come out different. [The README](README.md#cache-busting-the-html-that-links-your-assets) says what it is for and how to switch it on; this is how it is computed.

The obvious implementation of "one hash covering everything" is a sweep: glob every mapped file, read it, hash it, hash the hashes. That works, and it is wasteful in a way that shows up on every single request — a recursive `Dir[]` across all your asset roots plus a read and a SHA-256 per file, all to re-derive numbers the dependency graph is already holding.

So Assiette uses the graph instead.

### Fingerprints already cascade upward

Recall how a fingerprint is built: a file with no dependencies gets the SHA-256 of its raw bytes, and a file with dependencies gets the SHA-256 of its *rewritten* content — the content with every import and `url()` carrying the fingerprint of the file it points at. Those referenced fingerprints were computed the same way, one level down. So a node's fingerprint is not a hash of that one file; it is a hash of that file's entire dependency subtree.

That property is the whole trick. If a node's fingerprint already covers everything below it, you don't need to hash everything below it again.

### Apexes

An **apex** is a node nothing else points at — no JS file imports it, no CSS file `url()`s it. In graph terms, its `dependents` set is empty. Take the fixtures in this repo:

```
application.css   test_with_url.css   logo.png   js/root_a.js   js/root_b.js
                                                      │
                                    ┌─────────────────┼─────────────────┐
                              js/mid/alpha       js/mid/beta      js/mid/gamma
                                    │                 │                 │
                              leaf/alpha_*       leaf/beta_*      leaf/gamma_*
```

The top row is the apex set. Each `leaf/*_*` is a pair of files, so that is fourteen files in total — and hashing those five fingerprints covers all fourteen, with each file contributing exactly once. Everything below the top row is reachable from something in it, and its content is already baked into that ancestor's fingerprint.

Note what falls out for free: `logo.png` and `application.css` are linked only from ERB. Assiette never parses your templates and has no idea they are referenced — but it doesn't need to. Nothing in the asset graph points at them, so they are apexes by construction and get hashed directly. This is why the digest catches images that a hand-rolled "ETag on my two entry points" approach misses.

### The cycle that has no apex

There is one shape this misses. If `a.js` imports `b.js` and `b.js` imports `a.js`, and nothing else imports either, then both nodes have a non-empty `dependents` set — they point at each other — so neither qualifies as an apex. And since no apex reaches them, they are not covered from above either. The pair would drop out of the digest silently, which is the worst kind of cache bug: everything looks fine until someone edits a file in the cycle and the page never revalidates.

The fix does not require tracking strongly connected components (the resolver builds that information transiently and throws it away once resolution finishes). Instead, `apex_paths` collects the apexes, walks down `deps` from each one marking everything it reaches, and then adopts any node in the graph that was never reached:

```ruby
(apexes + (@assets.keys - reached.to_a)).sort
```

An unreferenced cycle is by definition a set of nodes no apex can reach, so it gets adopted wholesale. This costs one traversal of a graph that is already in memory.

### Names are part of the hash

The digest folds in each apex's URL path alongside its fingerprint, separated by NULs:

```ruby
combined << url_path << "\0" << tree_sha(url_path).to_s << "\0"
```

Fingerprints alone would miss a pure rename. Move `logo.png` to `brand.png` without touching a byte and every fingerprint in the graph stays identical — but the HTML changes, because the `src` changes. Hashing the path catches that, and it catches additions and deletions by the same mechanism.

### Populating the graph first

There is a trap here. The graph is lazy by design, so the apex set means nothing until it is fully populated — you get a different answer depending on what the process happens to have served so far. Measured on the fixtures in this repo:

| Graph state | Nodes | Apexes |
| --- | --- | --- |
| Cold handler | 0 | 0 |
| After serving `js/root_a.js` | 10 | 1 |
| Fully populated | 14 | 5 |

Two Puma workers that had served different pages would compute different ETags for byte-identical content, and the resulting cache thrash would look random. So `digest` calls `ensure_graph_populated!` first, which walks every mapped file once and forces it into the graph.

That walk is the expensive part, and it is amortised behind a directory-mtime guard rather than repeated per call. Directory mtimes move when an entry is added, removed or renamed — exactly the events that change the file list. Editing a file in place does *not* move them, and does not need to: the graph checks per-file mtimes on every access, so an edit anywhere in a subtree is picked up when the digest reads its apex's fingerprint.

Checking the guard is one `stat` per directory under the mapped roots — **every** directory, not only the ones holding a servable file. Watching just the file-bearing ones leaves a hole exactly where it does the most damage: adding `app/assets/js/new_thing/a.js` moves the mtime of `app/assets/js`, but if that directory holds no servable file of its own it was never watched, and the new asset stays invisible. Every page keeps validating while its HTML has no idea the file exists. The extra directories cost around 1.6µs each per call — not measurable on the fixtures here, and 0.88ms to 1.5ms on a deliberately directory-heavy tree (401 directories, 100 files). Correctness is worth that.

The re-walk also prunes nodes whose files have disappeared. A deleted file that something still imports is dropped as a side effect of resolving its dependents, but a deleted orphan is never revisited and would otherwise linger in the graph as a phantom apex, holding the digest still across a deletion.

### What it costs

Warm, per call, on the fixtures in this repo and on a 514-file tree:

| | 14 files | 514 files |
| --- | --- | --- |
| Apex digest | 0.115ms | 3.238ms |
| Full sweep over every mapped file | 1.386ms | 25.243ms |
| `digest_for`, 2 names ([below](#scoping-it-down)) | 0.047ms | 0.064ms |

The difference between the first two is not asymptotic — both walk every node. It is I/O. The sweep globs, reads and SHA-256s every file on every call. The apex digest globs only when a directory mtime moved, and otherwise does an in-memory traversal plus one `File.mtime` per node, re-reading and re-hashing only the files that actually changed. On a request where nothing changed, which is nearly all of them, it touches no file contents at all.

### Concurrent population

On a cold handler two threads can populate the graph at the same time. This is harmless: the graph holds its own mutex, so the work is duplicated but never corrupted, and both threads arrive at the same digest.

### Scoping it down

The apex digest answers "did *anything* change?". A page only needs the narrower question — "did anything **I link** change?" — and `AssetHandler#digest_for(url_paths)` answers that one, over a set the caller names instead of the apex set:

```ruby
def digest_for(url_paths)
  combined = Digest::SHA256.new
  url_paths.map { |path| path.sub(%r{\A/}, "") }.uniq.sort.each do |url_path|
    combined << url_path << "\0" << @dependency_graph.tree_sha(url_path).to_s << "\0"
  end
  combined.hexdigest[0, 16]
end
```

Same body, and — see the table above — not a small variation in cost. The apex digest grows with the asset directory; this grows with the page. Nothing has to be *discovered*, so `ensure_graph_populated!` is not called and no directory is globbed — the input is a list of names, and the work is one `File.mtime` per named node and per node underneath it that the graph already holds. A handful of names is enough because of the property the apex digest already leans on, applied one level down: a node's fingerprint is the SHA-256 of its *rewritten* content, which carries the fingerprints of everything it imports. Naming `js/root_a.js` covers the three mid files and six leaves below it.

What it cannot do is decide *which* names to hash on a page's behalf. `etag` blocks are evaluated in `combine_etags`, inside `fresh_when` — in the action, before the template renders — so at the moment a validator is assembled, which assets that response is about to link is not knowable, and the request that would most like to know is exactly the one about to answer 304 without rendering. Anything learned from previous renders is a guess, and a guess that is wrong in the unsafe direction serves stale HTML. So `include_assiette_etags!` stays on the apex digest, and `digest_for` is there for a page whose entry points its author knows and can simply name.
