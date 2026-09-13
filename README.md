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

For a deeper dive into the internals — the request lifecycle, the dependency graph, and how the HTML digests are computed — see [ARCHITECTURE.md](ARCHITECTURE.md).

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

### Varying the served directories per request

A single `Assiette::Server` is normally built around one `AssetHandler` for the life of the process. If the set of directories you want to serve depends on the request — a multi-tenant app where every tenant has its own asset directory, say — pass something callable instead of a handler. It is called once per request with the Rack `env` and returns the handler to use, or `nil`:

```ruby
Rails.application.config.middleware.use Assiette::Server, ->(env) {
  tenant = Tenant.find_by(host: env["HTTP_HOST"])
  tenant && Assiette::AssetHandler.new(root: tenant.assets_root)
}
```

Returning `nil` means "nothing to serve for this request": the request passes straight through to the rest of the stack, and the view helpers do not see this middleware at all.

Build the handlers up front and cache them per tenant rather than allocating one on every request — a handler holds the dependency graph, and a fresh one starts cold, so building one per request throws the fingerprint cache away each time.

Because handlers are per-request, this composes with mounting several `Assiette::Server`s: give a tenant its own directory through a callable and keep a second, plain `Assiette::Server` for the assets everyone shares. The view helpers search every handler on the stack (see below), so a page can link assets from either.

### Serving additional file types

Out of the box a handler serves `.js`, `.mjs`, `.css`, `.svg`, `.png`, `.jpg`, `.jpeg` and `.ico`. Anything else gets a 404 and falls through to the rest of your Rack stack. Give a handler `content_types:` to teach that handler — and only that handler — about more:

```ruby
handler = Assiette::AssetHandler.new(
  root: Rails.root.join("app/assets"),
  content_types: {
    ".woff2" => "font/woff2",
    ".webp" => "image/webp"
  }
)

Rails.application.config.middleware.use Assiette::Server, handler
```

The mapping is merged over the defaults, so it can also override one of them for this handler alone. Nothing is registered globally: a second handler elsewhere in the same process keeps refusing `.woff2`, which is what you want when your mounts serve directories with different rules.

Extensions are normalized — the leading dot is optional and case is ignored, so `"woff2"`, `".woff2"` and `".WOFF2"` all register the same thing. Files on disk are matched case-insensitively too, so `PHOTO.JPG` is served as `image/jpeg` like any other JPEG.

Registered extensions are served *and* walked: the file shows up in the handler's dependency graph, gets a `?s=` fingerprint, and moves the [ETag of the pages linking it](#cache-busting-the-html-that-links-your-assets) when it changes. `handler.content_types` returns the effective mapping and `handler.content_type_for("/photos/beach.JPG")` returns the content type this handler would serve a path as, or `nil` if it would not serve it at all.

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

Returns the URL path with a `?s=` cache-busting content hash appended. Returns `nil` if no handler has the file.

### `assiette_asset_integrity(path)`

Returns the `sha256-...` SRI hash for the served content (after import rewriting). Returns `nil` if the file is not found.

Both search every `Assiette::Server` that ran for this request, innermost first, and use the first handler that actually has the file. With one Server mounted there is nothing to search; with several, the innermost one does not necessarily hold the asset a page is asking for.

### `assiette_stylesheet_tag(path)`

Renders a `<link rel="stylesheet">` tag with `integrity` and `crossorigin` attributes.

### `assiette_modulepreload_tags`

Scans the asset roots for `.js`/`.mjs` files containing ES `import`/`export` statements and renders `<link rel="modulepreload">` tags for each, with SRI integrity hashes.

Unlike the two helpers above this one does *not* search the stack — it stays scoped to the innermost `Assiette::Server`. It renders a listing of everything a handler holds, and with per-tenant handlers walking the stack would put one tenant's file list on another tenant's page. Mount the Server holding the modules you want preloaded innermost.

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

### Cache busting the HTML that links your assets

> **TL;DR** — if any of your controllers call `fresh_when` or `stale?`, you almost certainly want `include_assiette_etags!` in your `ApplicationController`. Without it, those responses keep validating after you edit an asset, and clients keep being handed HTML that links the previous `?s=` hash.

Fingerprinted asset URLs only help if the browser fetches the HTML carrying them. A page's ETag is usually built from the code revision plus some model cache keys — editing a stylesheet moves neither. The response still validates, your caching layer returns a `304 Not Modified`, and the stored HTML keeps pointing at the previous `?s=` hash. Assiette had the new fingerprint the whole time; nobody asked for it.

`include_assiette_etags!` asks for it:

```ruby
class ApplicationController < ActionController::Base
  include_assiette_etags!
end
```

That is the whole setup — no arguments, no entry points to name. It registers a Rails `etag` block, so it applies to every response where you call `fresh_when` or `stale?`. The macro is installed on `ActionController::Base` by the Railtie, and it resolves the handler off the Rack env, so it works in both mode 1 and mode 2, and picks the right handler when an engine mounts a second one.

The value it contributes is a digest of the assets **that page links** — the URLs its helpers emitted, each one standing in for everything it imports. Edit a stylesheet and the pages linking it stop validating; the pages that never mentioned it keep their 304s.

That a referenced node can stand in for its whole subtree is the same property the `?s=` hashes rely on: a file's fingerprint is a hash of its *rewritten* content, so it already folds in the fingerprint of everything it imports, recursively. A page linking one entry module is fully covered by that one module's fingerprint, however many files hang off it.

#### Predict, then settle

Answering "not modified" *without rendering* is the entire point of a conditional GET, so the ETag has to exist before the template runs — and before the template runs, which assets it links is not knowable. Rails evaluates `etag` blocks inside `fresh_when`, in the action. So two different values do two different jobs:

- **Before the render**, the macro *predicts* the page's links from what the last render of the same page left in a per-process log on the handler, and folds that digest in. This is the value the 304 decision is made against. With nothing remembered it predicts `AssetHandler#digest` — coarser, never weaker.
- **After the render**, the true set is known, so the macro reissues the ETag from it. That is the value the client stores.

So a mispredicting worker — one that has just booted, say — costs a render, and only a render. It does not hand out a different ETag from its warm neighbours, and because the settled ETag still matches what the client sent, `Rack::ConditionalGet` turns the response into a `304` on the way out: the body does not go over the wire either.

#### What this covers, and what it does not

For a stale prediction to cost *freshness* rather than a render, a page would have to change **which** assets it links while everything else in its validator stood still. Two things stand in the way of that:

- Rails already folds the template digest into the ETag (`ActionController::EtagWithTemplateDigest`, on by default). Links that come from the template cannot change without moving it.
- A page that renders a *listing* of a handler's assets rather than naming them — `assiette_modulepreload_tags` — is detected and scoped to the whole handler automatically, because "every module there is" is not describable as a set of remembered paths. Such a page folds in `AssetHandler#digest` and busts whenever any module appears, disappears or changes.

What is left is a page whose link set is driven by data rather than by its template — `image_tag(@product.photo_path)` — *and* whose validator does not include that data. Put the record in the validator, as you would anyway, and it is covered.

Two smaller things worth knowing: the log is keyed by host, path and format, so two variants of one path that link different assets share a slot and mispredict each other (a render apiece, nothing more); and it holds 2048 pages per process, evicting the least recently rendered.

#### Asking for the coarse guarantee instead

```ruby
class ApplicationController < ActionController::Base
  include_assiette_etags!(digest: :all)
end
```

That folds in `AssetHandler#digest`: one hash covering **every** asset the handler can serve. Change any of them — content, name, or the file list itself — and every page that could link an Assiette URL stops validating. It needs no warm-up, no remembered state and no settling, and it costs a walk of the whole graph on every request rather than of one page's links. On this repo's fixtures (14 files) that is 0.115ms against 0.053ms; on a 514-file tree, 3.3ms against 0.061ms, because only one of the two grows with the size of your asset directory.

One gotcha specific to `:all`: a brand-new *directory* is noticed through its parent's mtime, and only if that parent itself directly contained at least one servable file. Adding `app/assets/js/new_thing/a.js` where `app/assets/js` holds no files of its own will not move the digest until something else does. Touching any directory that does hold servable files fixes it. The default mode does not have this problem for the pages that name their links — it hashes the assets it was given rather than discovering them — but a listing page falls back to `:all` and inherits it.

## License

MIT
