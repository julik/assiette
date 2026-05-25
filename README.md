# Assiette

[![CI](https://github.com/julik/assiette/actions/workflows/ci.yml/badge.svg)](https://github.com/julik/assiette/actions/workflows/ci.yml)

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

## Rails asset pipeline integration

Assiette can be used in two modes. Pick the one that fits how much of Rails' asset machinery you want it to take over.

### Mode 2: Assiette as the Rails asset resolver (default)

This is what the install generator sets up. Assigning an `Assiette::AssetHandler` to `Rails.application.assets` is the single switch that flips mode 2 on — the helper override is wired into `ActionView` by the Railtie and is inert until that assignment happens. The standard Rails asset helpers — `asset_path`, `image_tag`, `stylesheet_link_tag`, `javascript_include_tag` — then resolve paths through Assiette and pick up its `?v=` cache-busting tag automatically. Assets Assiette cannot resolve fall through to Rails' default behavior, so this mode is safe to mix with fonts or other files Rails serves directly.

Use this when:

- Assiette is your asset pipeline. You're not running Sprockets or Propshaft, and you'd rather write `image_tag "logo.svg"` than `assiette_asset_path "/logo.svg"`.
- You want existing Rails code (gems, view partials, scaffolds) to pick up Assiette's version tag without rewriting every `asset_path` call.

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
<%# => <img src="/logo.svg?v=...">

<%= stylesheet_link_tag "app" %>
<%# => <link rel="stylesheet" href="/app.css?v=...">
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

The version tag is computed once per boot:

- **Development:** current timestamp (changes every request)
- **Production with `APP_REVISION`:** derived from the env var
- **Production without:** derived from `Gemfile.lock` digest

Relative imports in JS (`./foo.js`, `../bar.js`) and `url()` references in CSS are automatically rewritten to include the version tag, so the entire dependency graph busts together.

## License

MIT
