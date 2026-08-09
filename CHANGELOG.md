# Changelog

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
