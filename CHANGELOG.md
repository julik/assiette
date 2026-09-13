# Changelog

## Unreleased

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
