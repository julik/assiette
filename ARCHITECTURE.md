# How Assiette works under the hood

This document is the internals. If you just want to install Assiette and serve some files, [README.md](README.md) is the place to be.

The approach is described in [this article](https://blog.julik.nl/2026/05/just-say-no-to-asset-pipelines) in detail — Assiette is simply the article packaged up as a gem. Here is the gist.

## Why this exists

There is really only one solid reason to have an asset pipeline: cache busting during deployments. When you push a new version of your app, users might still have old JavaScript cached in their browsers. If your HTML references fingerprinted URLs, the browser knows to fetch fresh copies. That part is genuinely useful, and Assiette does that.

The trouble is everything else that comes with it. Traditional pipelines — Sprockets, Propshaft, Webpack, the various esbuild wrappers — demand a build step, a manifest file, a separate compilation phase in CI, configuration for every new file, and often a Node.js runtime sitting alongside your Ruby app. Importmap-rails calls itself "nobuild" but still requires you to manually `pin` every module you add. Forget to run the command after creating `helpers.js` and things just quietly don't work. That kind of busywork benefits nobody.

Assiette takes a different position: you should be able to drop a `.js` or `.css` file into a directory and have it served immediately, with proper cache busting, without touching a config file or running a command. Adding a source file to your project should not be a ceremony.

## What happens when a request comes in

Assiette is a Rack middleware. When it sees a GET request for a path that maps to a file with a known extension (`.js`, `.mjs`, `.css`, `.svg`, `.png`, `.jpg`, `.jpeg`, `.ico`, plus whatever the handler was given through `content_types:`), it resolves the file through its dependency graph, which gives it a content hash. That hash becomes the ETag. If the browser sends back a matching `If-None-Match` header, Assiette returns a `304 Not Modified` without even reading the file from disk, and that's the end of it.

For JS and CSS files, Assiette does one extra thing before serving: it scans the file for relative `import` statements (in JS) and `url()` references (in CSS) and appends a `?s=<content-hash>` query parameter to each one. The hash comes from the content of the file being referenced — after that file's own imports have been rewritten too — so the fingerprints cascade through the entire import tree. The scanning is done with lightweight regexes, not a full parser, and it only looks at paths that are clearly relative or absolute filesystem references. Protocol URLs, data URIs, and anything that looks like a remote resource is left alone.

The response goes out with `Cache-Control: public, max-age=432000, must-revalidate` and the ETag. If the request doesn't match any known asset extension, the middleware passes it straight through to the next app in the Rack stack — Assiette never interferes with your controllers or API routes.

## The handler stack

Which files a `Server` can serve is decided by its `AssetHandler`. Usually there is one, built when the middleware is constructed. It can also be resolved per request: pass something callable instead of a handler and it is called once, at the top of `#call`, with the Rack env. That is what lets a multi-tenant application serve a different directory per tenant through one middleware entry. Returning `nil` from it means "not mine": the request passes through untouched, and — importantly — nothing is recorded for it.

What gets recorded is `env["assiette.stack"]`. Every `Server` that runs appends `{handler:, script_name:}` to it, so by the time a controller renders, the array holds one entry per Server that saw the request, outermost first. The `SCRIPT_NAME` is captured at that moment rather than at render time, which is what makes an engine mounted at `/admin` produce `/admin/app.css` while the host app's own Server produces `/app.css`.

The view helpers read that array. `assiette_asset_path` and `assiette_asset_integrity` walk it from the innermost entry outwards and use the first handler whose `resolve_file` actually finds the file. Taking only the last entry — which is what they used to do — works fine until a second Server is mounted, at which point the innermost one silently wins and an asset belonging to an outer handler resolves to `nil`. Walking costs one `resolve_file` per entry, which is a `stat` on a path the handler has already mapped, and stops at the first hit.

`assiette_modulepreload_tags` deliberately does not walk. It renders a listing of *everything* a handler holds, so searching outwards would mean emitting one tenant's file list on another tenant's page. It stays scoped to the innermost entry; mount the Server whose modules you want preloaded innermost.

`include_assiette_etags!` reads the whole array too, and for the same reason: it folds in one apex digest per entry. Taking only the last would leave a page validating after an asset it links from an outer handler changed — which the helpers will happily have given it a URL for.

## The dependency graph

The import rewriting is backed by a lazy dependency graph, one node per file. A node's fingerprint is a SHA-256 of its *rewritten* content — the content with every import already carrying the fingerprint of the file it points at — so a fingerprint covers the file's entire dependency subtree, not just its own bytes. That is what lets one `?s=` on an entry module bust everything hanging off it.

Nothing is built at startup, and a file nobody requests is never read. Staleness is per-file, checked with `File.mtime` on every access, so an edit is picked up by the next request touching that file or anything importing it — no restart, no manifest, no compilation step. Cyclic imports are detected during resolution and treated as one unit.

[DEPENDENCY_GRAPH.md](DEPENDENCY_GRAPH.md) has the rest: how resolution and cycle detection work, how a change propagates to dependents, and how the apex digest is derived.

## Module preloading

Because ES modules are discovered by the browser as JavaScript arrives and gets parsed, they can't be loaded in parallel unless you predeclare them. Assiette handles this by scanning your asset directories for `.js` and `.mjs` files that contain `import` or `export` statements and generating `<link rel="modulepreload">` tags for all of them. This scan is separate from the dependency graph — it just looks at files and checks whether they look like ES modules. The SRI integrity hash for each module is then computed lazily through the dependency graph when the preload tag is actually rendered.

## The page digest

`AssetHandler#digest` is one hash covering every asset a handler can serve. It exists so that a page linking Assiette URLs stops validating as soon as any of those URLs would come out different — see [Cache busting the HTML that links your assets](README.md#cache-busting-the-html-that-links-your-assets) for what it is for and how to switch it on, and [DEPENDENCY_GRAPH.md](DEPENDENCY_GRAPH.md#the-apex-digest) for how it is computed.

The short version: rather than sweeping every mapped file on every request, it hashes the graph's *apexes* — the nodes nothing else imports — whose fingerprints already fold in everything they reach. `include_assiette_etags!` folds one in per handler on the request's stack. `AssetHandler#digest_for` is the same hash over a set of paths the caller names instead, for a page that knows its own entry points.

## Staying out of your way (and how to get rid of it)

Assiette has no configuration file, no manifest, no build step, and no CLI commands. There is nothing to "compile" or "precompile". You add files and they get served; you remove them and they stop being served. That is the whole workflow.

More importantly, Assiette is designed so that you can remove it entirely without rewriting your application. Your JS files are plain ES modules with standard relative imports — they work in any browser without Assiette, because the `?s=` query parameters are simply ignored by the module loader. You could serve the same files with nginx, a CDN, or `python -m http.server` and everything would still run. Your CSS files use standard `url()` references, same deal. There is no proprietary import syntax, no loader plugins, no magic path resolution that would tie you to the gem.

If you are using Assiette's Rails integration (the Mode 2 setup where it hooks into the standard Rails helpers), removing it is a single-line change: delete the `Rails.application.assets = handler` assignment and the standard Rails asset resolution kicks back in. The `assiette_*` view helpers would stop working, but they can be replaced with plain `<link>` and `<script>` tags pointing at the same file paths — because the files themselves haven't changed.

The trade-off is straightforward: you give up tree-shaking, TypeScript, JSX, and the npm ecosystem. What you get in return is files that are just files, served as-is, with no build artifacts, no compilation caches, and no native dependencies. An HTML page with a few ES modules served through Assiette today will still work in ten years, because it relies on nothing but the browser and the HTTP spec. That kind of longevity is worth something.
