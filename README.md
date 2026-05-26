# Assiette

[![CI](https://github.com/julik/assiette/actions/workflows/ci.yml/badge.svg)](https://github.com/julik/assiette/actions/workflows/ci.yml)

> L'assiette, c'est pour servir les assets.

It is a slightly unhinged Rails asset server. It will serve your SVG, images, CSS and JS allowing for true nobuild (but also noconfig) asset serving. See, importmaps-rails is not really "nobuild" - it has to be managed. With Assiette, you drop a file into your directory and you're off to the races.

The approach is described in [this article](https://blog.julik.nl/2026/05/just-say-no-to-asset-pipelines) in more detail - this gem simply packages it in a library.

Assiette does help with cache-busting and preloading:

- Content-hash cache busting (`?s=...`)
- Automatic rewriting of relative `import` paths in JS and `url()` in CSS
- SRI integrity hashes
- `<link rel="modulepreload">` generation for all detected ES modules
- ETag / 304 support

No asset pipeline, no Node.js, no build step. And no importmap commands. Oh - and you can freely use relative JS imports, as the original spec intended. When used inside an engine, Assiette does not conflict with any other Rails asset pipeline setups - it is isolated to the URL namespaces you choose. It also uses no pre-processors, bundlers, compilers, runtimes or native shared libraries of any kind.

Assiette does not support sourcemaps because... all the rewriting it does is at the level of URLs, so your line numbers won't shift.

## How does it work?

Assiette is a Rack middleware that serves static assets directly from disk, adding some light pre-processing and globbing on top. The middleware can be installed into a Rails app, or into an Rails engine which lives inside a host application, or used standalone as a Rack middleware. Assiette takes care to record the `SCRIPT_NAME` of the request, which allows multiple instances of Assiette to be mounted and permits Assiette to be used inside nested Rack apps which, themselves, set `SCRIPT_NAME` - like Sinatra.

For a deeper dive into the internals, see [How Assiette works under the hood](#how-assiette-works-under-the-hood) at the bottom of this document.

## Installation

Add to your Gemfile:

```ruby
gem "assiette"
```

Then run the install generator:

```
bin/rails generate assiette:install
```

This creates `config/initializers/assiette.rb` which serves files from `app/assets` and `public/` and wires Assiette into the standard Rails asset helpers (see [Rails asset pipeline integration](#rails-asset-pipeline-integration) below). If you'd prefer a lighter-touch setup, or want to configure things by hand, see the [Manual setup](#manual-setup) and [Mode 1](#mode-1-assiette-alongside-rails) sections.

### Manual setup

If you prefer to configure manually, add `Assiette::Server` to your middleware stack. Each instance serves files from one root directory.

```ruby
# config/initializers/assiette.rb

# Serve from app/assets (JS modules, CSS, SVGs)
Rails.application.config.middleware.use Assiette::Server,
  root: Rails.root.join("app/assets")

# Serve from public/ (favicons, static images)
Rails.application.config.middleware.use Assiette::Server,
  root: Rails.root.join("public")

# Make helpers available in all views
ActiveSupport.on_load(:action_controller_base) do
  helper Assiette::Helpers
end
```

### Serving from additional directories under a URL prefix

Use `additional_directory_mappings` to serve files from extra directories, each under its own URL prefix:

```ruby
Rails.application.config.middleware.use Assiette::Server,
  root: Rails.root.join("app/assets"),
  additional_directory_mappings: {
    "/vendor" => Rails.root.join("vendor/assets"),
    "/icons"  => Rails.root.join("app/icons")
  }
```

With this setup a file at `vendor/assets/datepicker.js` is served at `/vendor/datepicker.js`, while files in `app/assets` are served from the root (`/application.css`). You can combine multiple mappings in a single middleware instance.

## Usage inside a Rails engine (gem)

Engines use `middleware.use` on the engine class, which scopes the middleware to requests that hit the engine's mount point. The `SCRIPT_NAME` is set automatically so view helpers resolve paths correctly.

```ruby
# lib/my_engine/engine.rb

module MyEngine
  class Engine < ::Rails::Engine
    isolate_namespace MyEngine

    initializer "my_engine.assets", before: :build_middleware_stack do |app|
      require "assiette" # All Assiette modules auto-resolve from here
      middleware.use Assiette::Server, root: Engine.root.join("public")
    end
  end
end
```

The `before: :build_middleware_stack` option is required for Rails 8.1+ where the middleware stack is frozen after the `:build_middleware_stack` initializer runs.

With this setup, if the host app mounts your engine at `/admin`:

```ruby
mount MyEngine::Engine => "/admin"
```

then a file at `my_engine/public/app.css` is served at `/admin/app.css`.

## View helpers

The install generator sets up the helpers automatically. If you configured Assiette manually, add this to your initializer so the helpers are available in all views:

```ruby
ActiveSupport.on_load(:action_controller_base) do
  helper Assiette::Helpers
end
```

If you only need the helpers in specific controllers, include them there instead:

```ruby
class SiteController < ApplicationController
  helper Assiette::Helpers
end
```

```erb
<%# Link a stylesheet with SRI integrity and content hash %>
<%= assiette_stylesheet_tag "/app.css" %>

<%# Get a cache-busted asset URL %>
<script type="module" src="<%= assiette_asset_path "/js/app.js" %>"></script>

<%# Preload all detected ES modules %>
<%= assiette_modulepreload_tags %>
```

### `assiette_asset_path(path)`

Returns the URL path with a `?s=` cache-busting content hash appended.

### `assiette_asset_integrity(path)`

Returns the `sha256-...` SRI hash for the served content (after import rewriting). Returns `nil` if the file is not found.

### `assiette_stylesheet_tag(path)`

Renders a `<link rel="stylesheet">` tag with `integrity` and `crossorigin` attributes.

### `assiette_modulepreload_tags`

Scans the asset roots for `.js`/`.mjs` files containing ES `import`/`export` statements and renders `<link rel="modulepreload">` tags for each, with SRI integrity hashes.

## Rails asset pipeline integration

Assiette can be used in two modes. Pick the one that fits how much of Rails' asset machinery you want it to take over.

### Mode 2: Assiette as the Rails asset resolver (default)

This is what the install generator sets up. Assigning an `Assiette::AssetHandler` to `Rails.application.assets` is the single switch that flips mode 2 on — the helper override is wired into `ActionView` by the Railtie and is inert until that assignment happens. The standard Rails asset helpers — `asset_path`, `image_tag`, `stylesheet_link_tag`, `javascript_include_tag` — then resolve paths through Assiette and pick up its `?s=` cache-busting content hash automatically. Assets Assiette cannot resolve fall through to Rails' default behavior, so this mode is safe to mix with fonts or other files Rails serves directly.

Use this when:

- Assiette is your asset pipeline. You're not running Sprockets or Propshaft, and you'd rather write `image_tag "logo.svg"` than `assiette_asset_path "/logo.svg"`.
- You want existing Rails code (gems, view partials, scaffolds) to pick up Assiette's content hash without rewriting every `asset_path` call.

The handler is built once and shared between the middleware and the view helpers, so both resolve files the same way:

```ruby
# config/initializers/assiette.rb

handler = Assiette::AssetHandler.new(
  root: Rails.root.join("app/assets"),
  additional_directory_mappings: {
    "/" => Rails.root.join("public")
  }
)

# Serve files through the shared handler
Rails.application.config.middleware.use Assiette::Server, handler

# Make the Rails asset helpers resolve through the same handler.
# This single assignment is what flips Assiette into "mode 2".
Rails.application.assets = handler

# Also expose assiette_asset_path, assiette_stylesheet_tag, etc.
ActiveSupport.on_load(:action_controller_base) do
  helper Assiette::Helpers
end
```

```erb
<%= image_tag "logo.svg" %>
<%# => <img src="/logo.svg?s=...">

<%= stylesheet_link_tag "app" %>
<%# => <link rel="stylesheet" href="/app.css?s=...">
```

`Assiette::RailsAssetUrlHelper` overrides `compute_asset_path` and only kicks in when `Rails.application.assets` is an `Assiette::AssetHandler` — if you leave it unset (or set it back to `nil`), the helper is inert and the standard Rails resolution path runs. The Railtie includes the helper module into `ActionView` for you; you only need to opt in by assigning the handler.

### Mode 1: Assiette alongside Rails

In this mode Assiette serves files through its Rack middleware, and you use its `assiette_*` view helpers explicitly. The standard Rails helpers (`asset_path`, `image_tag`, `stylesheet_link_tag`, `javascript_include_tag`) keep going through whatever you have configured upstream — Sprockets, Propshaft, or nothing. `Rails.application.assets` is left alone.

Use this when:

- You want Assiette to coexist with an existing asset pipeline (Sprockets, Propshaft, importmap-rails).
- You only want Assiette to handle a subset of your assets, and you are happy calling `assiette_stylesheet_tag` / `assiette_asset_path` directly in templates.
- You are mounting Assiette inside an engine and don't want it to touch the host application's helpers.

```ruby
# config/initializers/assiette.rb

Rails.application.config.middleware.use Assiette::Server,
  root: Rails.root.join("app/assets")

ActiveSupport.on_load(:action_controller_base) do
  helper Assiette::Helpers
end
```

```erb
<%= assiette_stylesheet_tag "/app.css" %>
<%= image_tag "logo.svg" %> <%# still goes through Sprockets/Propshaft/etc. %>
```

## Cache busting

Every served file gets a content-based fingerprint — a short hex hash derived from the SHA-256 digest of the file's contents (after import rewriting). The hash appears as a `?s=abcd1234` query parameter on asset URLs. Relative imports in JS (`./foo.js`, `../bar.js`) and `url()` references in CSS are rewritten to include the content hash of the file they point to, so when you change a leaf module, the fingerprints of every file that imports it change too, transitively, all the way up the tree. You don't have to think about this — it just happens.

The dependency graph behind this is built lazily. Only files that are actually requested (and their transitive imports) are ever scanned and hashed. If you have two thousand orphan files sitting in your asset directories that nobody imports or requests, they are never touched. Staleness is tracked per-file using `File.mtime`, so when you save a file in your editor, the next request picks up the change automatically. No restart, no recompile, no nothing.

## How Assiette works under the hood

The approach is described in [this article](https://blog.julik.nl/2026/05/just-say-no-to-asset-pipelines) in detail — Assiette is simply the article packaged up as a gem. Here is the gist.

### Why this exists

There is really only one solid reason to have an asset pipeline: cache busting during deployments. When you push a new version of your app, users might still have old JavaScript cached in their browsers. If your HTML references fingerprinted URLs, the browser knows to fetch fresh copies. That part is genuinely useful, and Assiette does that.

The trouble is everything else that comes with it. Traditional pipelines — Sprockets, Propshaft, Webpack, the various esbuild wrappers — demand a build step, a manifest file, a separate compilation phase in CI, configuration for every new file, and often a Node.js runtime sitting alongside your Ruby app. Importmap-rails calls itself "nobuild" but still requires you to manually `pin` every module you add. Forget to run the command after creating `helpers.js` and things just quietly don't work. That kind of busywork benefits nobody.

Assiette takes a different position: you should be able to drop a `.js` or `.css` file into a directory and have it served immediately, with proper cache busting, without touching a config file or running a command. Adding a source file to your project should not be a ceremony.

### What happens when a request comes in

Assiette is a Rack middleware. When it sees a GET request for a path that maps to a file with a known extension (`.js`, `.mjs`, `.css`, `.svg`, `.png`, `.ico`), it resolves the file through its dependency graph, which gives it a content hash. That hash becomes the ETag. If the browser sends back a matching `If-None-Match` header, Assiette returns a `304 Not Modified` without even reading the file from disk, and that's the end of it.

For JS and CSS files, Assiette does one extra thing before serving: it scans the file for relative `import` statements (in JS) and `url()` references (in CSS) and appends a `?s=<content-hash>` query parameter to each one. The hash comes from the content of the file being referenced — after that file's own imports have been rewritten too — so the fingerprints cascade through the entire import tree. The scanning is done with lightweight regexes, not a full parser, and it only looks at paths that are clearly relative or absolute filesystem references. Protocol URLs, data URIs, and anything that looks like a remote resource is left alone.

The response goes out with `Cache-Control: public, max-age=432000, must-revalidate` and the ETag. If the request doesn't match any known asset extension, the middleware passes it straight through to the next app in the Rack stack — Assiette never interferes with your controllers or API routes.

### The dependency graph

The import rewriting is backed by a lazy dependency graph. It is not built at startup. The first time a file is requested, Assiette resolves its URL path to an absolute file path, reads it, extracts the imports, and then recursively does the same for each dependency. Digests are computed bottom-up: leaf files (with no imports of their own) get a straightforward SHA-256 of their raw content, and files with dependencies get a SHA-256 of their rewritten content, which already includes the hashes of everything they import. This means each file's fingerprint reflects the content of its entire dependency subtree.

Because the graph is lazy, files that nobody ever requests are never loaded into it. You can have a large asset directory with plenty of files that are only used in certain contexts, and only the ones that are actually served will be scanned. Staleness is checked per-file on each access using `File.mtime` — when a file changes on disk, the next request that touches it (or anything that depends on it) re-reads, re-parses, and recomputes digests up through all the dependents that are already in the graph.

Cyclic imports — the kind where `a.js` imports `b.js` and `b.js` imports `a.js` — are detected during the recursive resolution. When a cycle is found, all its members get the same digest, computed from their combined raw contents sorted by path. It is a pragmatic solution: the cycle is treated as a single unit, and changing any member causes all of them to bust. This matches what the browser actually does with circular ES module dependencies, so it works out fine in practice.

### Module preloading

Because ES modules are discovered by the browser as JavaScript arrives and gets parsed, they can't be loaded in parallel unless you predeclare them. Assiette handles this by scanning your asset directories for `.js` and `.mjs` files that contain `import` or `export` statements and generating `<link rel="modulepreload">` tags for all of them. This scan is separate from the dependency graph — it just looks at files and checks whether they look like ES modules. The SRI integrity hash for each module is then computed lazily through the dependency graph when the preload tag is actually rendered.

### Staying out of your way (and how to get rid of it)

Assiette has no configuration file, no manifest, no build step, and no CLI commands. There is nothing to "compile" or "precompile". You add files and they get served; you remove them and they stop being served. That is the whole workflow.

More importantly, Assiette is designed so that you can remove it entirely without rewriting your application. Your JS files are plain ES modules with standard relative imports — they work in any browser without Assiette, because the `?s=` query parameters are simply ignored by the module loader. You could serve the same files with nginx, a CDN, or `python -m http.server` and everything would still run. Your CSS files use standard `url()` references, same deal. There is no proprietary import syntax, no loader plugins, no magic path resolution that would tie you to the gem.

If you are using Assiette's Rails integration (the Mode 2 setup where it hooks into the standard Rails helpers), removing it is a single-line change: delete the `Rails.application.assets = handler` assignment and the standard Rails asset resolution kicks back in. The `assiette_*` view helpers would stop working, but they can be replaced with plain `<link>` and `<script>` tags pointing at the same file paths — because the files themselves haven't changed.

The trade-off is straightforward: you give up tree-shaking, TypeScript, JSX, and the npm ecosystem. What you get in return is files that are just files, served as-is, with no build artifacts, no compilation caches, and no native dependencies. An HTML page with a few ES modules served through Assiette today will still work in ten years, because it relies on nothing but the browser and the HTTP spec. That kind of longevity is worth something.

## License

MIT
