# Assiette

> L'assiette, c'est pour servir les assets.

It is a slightly unhinged Rails asset server. It will serve your SVG, images, CSS and JS allowing for true nobuild (but also noconfig) asset serving. See, importmaps-rails is not really "nobuild" - it has to be managed. With Assiette, you drop a file into your directory and you're off to the races.

The approach is described in [this article](https://blog.julik.nl/2026/05/just-say-no-to-asset-pipelines) in more detail - this gem simply packages it in a library.

Assiette does help with cache-busting and preloading:

- Cache-busting version tags (`?v=...`)
- Automatic rewriting of relative `import` paths in JS and `url()` in CSS
- SRI integrity hashes
- `<link rel="modulepreload">` generation for all detected ES modules
- ETag / 304 support

No asset pipeline, no Node.js, no build step. And no importmap commands. Oh - and you can freely use relative JS imports, as the original spec intended. When used inside an engine, Assiette does not conflict with any other Rails asset pipeline setups - it is isolated to the URL namespaces you choose. It also uses no pre-processors, bundlers, compilers, runtimes or native shared libraries of any kind.

Assiette does not support sourcemaps because... all the rewriting it does is at the level of URLs, so your line numbers won't shift.

## How does it work?

Assiette is a Rack middleware that serves static assets directly from disk, adding some light pre-processing and globbing on top. The middleware can be installed into a Rails app, or into an Rails engine which lives inside a host application, or used standalone as a Rack middleware. Assiette takes care to record the `SCRIPT_NAME` of the request, which allows multiple instances of Assiette to be mounted and permits Assiette to be used inside nested Rack apps which, themselves, set `SCRIPT_NAME` - like Sinatra.

## Installation

Add to your Gemfile:

```ruby
gem "assiette"
```

Then run the install generator:

```
bin/rails generate assiette:install
```

This creates `config/initializers/assiette.rb` which sets up middleware for `app/assets` and `public/`. But if you feel truly minimal, you can set up Assiette in your `config/application.rb` instead.

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
```

## Usage inside a Rails engine (gem)

Engines use `middleware.use` on the engine class, which scopes the middleware to requests that hit the engine's mount point. The `SCRIPT_NAME` is set automatically so view helpers resolve paths correctly.

```ruby
# lib/my_engine/engine.rb

module MyEngine
  class Engine < ::Rails::Engine
    isolate_namespace MyEngine

    initializer "my_engine.assets", before: :build_middleware_stack do |app|
      require "assiette/server"
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

Assiette injects helpers into all ActionView contexts and ActionControllersautomatically.

```erb
<%# Link a stylesheet with SRI integrity and version tag %>
<%= assiette_stylesheet_tag "/app.css" %>

<%# Get a cache-busted asset URL %>
<script type="module" src="<%= assiette_asset_path "/js/app.js" %>"></script>

<%# Preload all detected ES modules %>
<%= assiette_modulepreload_tags %>
```

### `assiette_asset_path(path)`

Returns the URL path with a `?v=` cache-busting tag appended.

### `assiette_asset_integrity(path)`

Returns the `sha256-...` SRI hash for the served content (after import rewriting). Returns `nil` if the file is not found.

### `assiette_stylesheet_tag(path)`

Renders a `<link rel="stylesheet">` tag with `integrity` and `crossorigin` attributes.

### `assiette_modulepreload_tags`

Scans the asset roots for `.js`/`.mjs` files containing ES `import`/`export` statements and renders `<link rel="modulepreload">` tags for each, with SRI integrity hashes.

## Cache busting

The version tag is computed once per boot:

- **Development:** current timestamp (changes every request)
- **Production with `APP_REVISION`:** derived from the env var
- **Production without:** derived from `Gemfile.lock` digest

Relative imports in JS (`./foo.js`, `../bar.js`) and `url()` references in CSS are automatically rewritten to include the version tag, so the entire dependency graph busts together.

## License

MIT
