# Changelog

## 0.6.0

- **Fix:** a fingerprint could lag the bytes it stands for. When a node's dependency was recomputed, the node's own dependents were not told — they compare their deps' digests from before and after their own visit, so a dep already updated during an earlier visit read as unchanged. Deleting `js/leaf/alpha_one.js` left `js/root_a.js` serving an import rewritten to the new `?s=` under its old fingerprint, so no browser holding the old copy ever refetched it. Recomputing a node now propagates to its dependents, as rescanning a stale one already did.
- **Fix:** the digest's directory-mtime guard watched only directories that held a servable file, so a new asset under a directory that held none was invisible — `app/assets/js/new_thing/a.js` where `app/assets/js` has no files of its own did not move `AssetHandler#digest`, and every page kept validating. It now watches every directory under the mapped roots. That costs around 1.6µs per extra directory per call: not measurable on ordinary trees, and 0.88ms to 1.5ms on a deliberately directory-heavy one (401 directories, 100 files).
- Add `AssetHandler#digest_for(url_paths)` — one hash over exactly the assets named, for a page that knows its entry points and wants a validator scoped to them rather than to everything the handler can serve. Name only the tops: a fingerprint already folds in the file's whole import subtree. There is no graph to populate first and no directory to glob, so the cost follows the page rather than the asset directory — 0.06ms against the apex digest's 3.3ms on a 514-file tree.
- `include_assiette_etags!` folds in one apex digest per handler on `env["assiette.stack"]`, not only the innermost one. Since the view helpers resolve an asset against the whole stack, a page can link an asset an outer handler serves — and used to keep validating after that asset changed.
- `Assiette::Server` accepts a callable in place of a handler. It is called once per request with the Rack env and returns the `AssetHandler` to use, so an application can vary the served directories per request — a multi-tenant app can hand every tenant its own asset root through one middleware entry. Returning `nil` passes the request through without recording anything on `env["assiette.stack"]`. Passing a plain handler works exactly as before.
- `assiette_asset_path` and `assiette_asset_integrity` now search the whole handler stack, innermost first, instead of only the last entry. With two `Assiette::Server`s mounted the innermost used to win unconditionally, so an asset belonging to an outer handler resolved to `nil`. They return `nil` when no handler in the stack has the file, and still raise when no Server ran at all.
- `assiette_modulepreload_tags` stays scoped to the innermost handler on purpose — it lists every module a handler holds, and walking the stack would put one tenant's file list on another tenant's page.
- Serve `.jpg` and `.jpeg` as `image/jpeg` by default. Asset directories holding photographs could not be served at all before.
- Add the `content_types:` argument to `AssetHandler.new`, merged over `CONTENT_TYPES` for that handler alone, so one mount can serve extra extensions without a process-wide allowlist that every other handler inherits. Extensions are normalized: the leading dot is optional, case is ignored, and files on disk are matched case-insensitively (`PHOTO.JPG` included).
- Add `AssetHandler#content_types` (the effective mapping) and `AssetHandler#content_type_for(path)` (nil for an extension the handler does not serve). `Server` resolves content types through the handler instead of reading `AssetHandler::CONTENT_TYPES` directly, and `#each_mapped_file` / `#js_modules` glob the handler's effective extensions, so a registered extension lands in the dependency graph rather than being served outside of it.

## 0.5.0

- Add `AssetHandler#digest` — an "apex digest": one hash covering every asset the handler can serve. Fold it into a page's ETag and the page stops validating as soon as any Assiette URL on it would come out different. Computed from the dependency graph's apexes rather than by sweeping every mapped file, and amortised behind a directory-mtime guard.
- Add `DependencyGraph#apex_paths`, returning the assets nothing imports or references. Cycles that nothing points into are adopted by walking down from the apexes and picking up whatever was never reached.
- Add `DependencyGraph#prune_deleted!`, which drops nodes whose files have disappeared. Orphans that nothing depends on were never revisited and used to linger in the graph.
- Add the `include_assiette_etags!` controller macro, installed on `ActionController::Base` by the Railtie. It resolves the handler off `env["assiette.stack"]`, so it works in mode 1 as well as mode 2 and picks the right handler when an engine mounts a second one.

## 0.2.0

- **Breaking:** Remove `Assiette::Engine`. View helpers are no longer auto-injected into every controller. Use `helper Assiette::Helpers` explicitly — the install generator adds this for you.
- Replace the Engine with a lightweight Railtie that only registers the install generator.
- Drop `railties` as a runtime dependency. The gem now only requires `actionpack`.
- Add explicit `require_relative` calls in `server.rb` so it works when required directly.
- Document `additional_directory_mappings` and per-controller helper usage in the README.

## 0.1.0

- Initial release
