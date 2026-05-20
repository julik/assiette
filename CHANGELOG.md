# Changelog

## 0.2.0

- **Breaking:** Remove `Assiette::Engine`. View helpers are no longer auto-injected into every controller. Use `helper Assiette::Helpers` explicitly — the install generator adds this for you.
- Replace the Engine with a lightweight Railtie that only registers the install generator.
- Drop `railties` as a runtime dependency. The gem now only requires `actionpack`.
- Add explicit `require_relative` calls in `server.rb` so it works when required directly.
- Document `additional_directory_mappings` and per-controller helper usage in the README.

## 0.1.0

- Initial release
