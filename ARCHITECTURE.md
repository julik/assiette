# How Assiette works under the hood

This document is the internals. If you just want to install Assiette and serve some files, [README.md](README.md) is the place to be.

The approach is described in [this article](https://blog.julik.nl/2026/05/just-say-no-to-asset-pipelines) in detail — Assiette is simply the article packaged up as a gem. Here is the gist.

## Why this exists

There is really only one solid reason to have an asset pipeline: cache busting during deployments. When you push a new version of your app, users might still have old JavaScript cached in their browsers. If your HTML references fingerprinted URLs, the browser knows to fetch fresh copies. That part is genuinely useful, and Assiette does that.

The trouble is everything else that comes with it. Traditional pipelines — Sprockets, Propshaft, Webpack, the various esbuild wrappers — demand a build step, a manifest file, a separate compilation phase in CI, configuration for every new file, and often a Node.js runtime sitting alongside your Ruby app. Importmap-rails calls itself "nobuild" but still requires you to manually `pin` every module you add. Forget to run the command after creating `helpers.js` and things just quietly don't work. That kind of busywork benefits nobody.

Assiette takes a different position: you should be able to drop a `.js` or `.css` file into a directory and have it served immediately, with proper cache busting, without touching a config file or running a command. Adding a source file to your project should not be a ceremony.

## What happens when a request comes in

Assiette is a Rack middleware. When it sees a GET request for a path that maps to a file with a known extension (`.js`, `.mjs`, `.css`, `.svg`, `.png`, `.ico`), it resolves the file through its dependency graph, which gives it a content hash. That hash becomes the ETag. If the browser sends back a matching `If-None-Match` header, Assiette returns a `304 Not Modified` without even reading the file from disk, and that's the end of it.

For JS and CSS files, Assiette does one extra thing before serving: it scans the file for relative `import` statements (in JS) and `url()` references (in CSS) and appends a `?s=<content-hash>` query parameter to each one. The hash comes from the content of the file being referenced — after that file's own imports have been rewritten too — so the fingerprints cascade through the entire import tree. The scanning is done with lightweight regexes, not a full parser, and it only looks at paths that are clearly relative or absolute filesystem references. Protocol URLs, data URIs, and anything that looks like a remote resource is left alone.

The response goes out with `Cache-Control: public, max-age=432000, must-revalidate` and the ETag. If the request doesn't match any known asset extension, the middleware passes it straight through to the next app in the Rack stack — Assiette never interferes with your controllers or API routes.

## The dependency graph

The import rewriting is backed by a lazy dependency graph. It is not built at startup. The first time a file is requested, Assiette resolves its URL path to an absolute file path, reads it, extracts the imports, and then recursively does the same for each dependency. Digests are computed bottom-up: leaf files (with no imports of their own) get a straightforward SHA-256 of their raw content, and files with dependencies get a SHA-256 of their rewritten content, which already includes the hashes of everything they import. This means each file's fingerprint reflects the content of its entire dependency subtree.

Because the graph is lazy, files that nobody ever requests are never loaded into it. You can have a large asset directory with plenty of files that are only used in certain contexts, and only the ones that are actually served will be scanned. Staleness is checked per-file on each access using `File.mtime` — when a file changes on disk, the next request that touches it (or anything that depends on it) re-reads, re-parses, and recomputes digests up through all the dependents that are already in the graph.

Cyclic imports — the kind where `a.js` imports `b.js` and `b.js` imports `a.js` — are detected during the recursive resolution. When a cycle is found, all its members get the same digest, computed from their combined raw contents sorted by path. It is a pragmatic solution: the cycle is treated as a single unit, and changing any member causes all of them to bust. This matches what the browser actually does with circular ES module dependencies, so it works out fine in practice.

## Module preloading

Because ES modules are discovered by the browser as JavaScript arrives and gets parsed, they can't be loaded in parallel unless you predeclare them. Assiette handles this by scanning your asset directories for `.js` and `.mjs` files that contain `import` or `export` statements and generating `<link rel="modulepreload">` tags for all of them. This scan is separate from the dependency graph — it just looks at files and checks whether they look like ES modules. The SRI integrity hash for each module is then computed lazily through the dependency graph when the preload tag is actually rendered.

## The apex digest

`AssetHandler#digest` is one hash covering every asset a handler can serve. It exists so that a page linking Assiette URLs stops validating as soon as any of those URLs would come out different — see [Cache busting the HTML that links your assets](README.md#cache-busting-the-html-that-links-your-assets) in the README for what it is for and how to switch it on. This section is about how it is computed.

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

That walk is the expensive part, and it is amortised behind a directory-mtime guard rather than repeated per call. Directory mtimes move when an entry is added, removed or renamed — exactly the events that change the file list. Editing a file in place does *not* move them, and does not need to: the graph checks per-file mtimes on every access, so an edit anywhere in a subtree is picked up when the digest reads its apex's fingerprint. Checking the guard is one `stat` per walked directory — around 0.012ms across the five directories in this repo's fixtures.

The re-walk also prunes nodes whose files have disappeared. A deleted file that something still imports is dropped as a side effect of resolving its dependents, but a deleted orphan is never revisited and would otherwise linger in the graph as a phantom apex, holding the digest still across a deletion.

### What it costs

Measured on the fixtures in this repo (14 files), warm:

| | per call |
| --- | --- |
| Apex digest | 0.145ms |
| Full sweep over every mapped file | 1.333ms |

On a real 24-file app the same comparison came out at 0.27ms against 1.73ms.

The difference is not asymptotic — both walk every node. It is I/O. The sweep globs, reads and SHA-256s every file on every call. The apex digest globs only when a directory mtime moved, and otherwise does an in-memory traversal plus one `File.mtime` per node, re-reading and re-hashing only the files that actually changed. On a request where nothing changed, which is nearly all of them, it touches no file contents at all.

### Two caveats

- A brand-new subdirectory is noticed through its parent's mtime only if that parent was itself walked, i.e. if it directly contained at least one servable file. Adding `app/assets/js/new_thing/a.js` where `app/assets/js` holds no files of its own will not be picked up until something else moves. In practice `app/assets` and its populated subdirectories are walked, so this is rare — but if you hit it, touch any walked directory.
- On a cold handler two threads can populate the graph concurrently. This is harmless: the graph holds its own mutex, so the work is duplicated but never corrupted, and both threads arrive at the same digest.

## Staying out of your way (and how to get rid of it)

Assiette has no configuration file, no manifest, no build step, and no CLI commands. There is nothing to "compile" or "precompile". You add files and they get served; you remove them and they stop being served. That is the whole workflow.

More importantly, Assiette is designed so that you can remove it entirely without rewriting your application. Your JS files are plain ES modules with standard relative imports — they work in any browser without Assiette, because the `?s=` query parameters are simply ignored by the module loader. You could serve the same files with nginx, a CDN, or `python -m http.server` and everything would still run. Your CSS files use standard `url()` references, same deal. There is no proprietary import syntax, no loader plugins, no magic path resolution that would tie you to the gem.

If you are using Assiette's Rails integration (the Mode 2 setup where it hooks into the standard Rails helpers), removing it is a single-line change: delete the `Rails.application.assets = handler` assignment and the standard Rails asset resolution kicks back in. The `assiette_*` view helpers would stop working, but they can be replaced with plain `<link>` and `<script>` tags pointing at the same file paths — because the files themselves haven't changed.

The trade-off is straightforward: you give up tree-shaking, TypeScript, JSX, and the npm ecosystem. What you get in return is files that are just files, served as-is, with no build artifacts, no compilation caches, and no native dependencies. An HTML page with a few ES modules served through Assiette today will still work in ten years, because it relies on nothing but the browser and the HTTP spec. That kind of longevity is worth something.
