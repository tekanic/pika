<p align="center">
  <img src="assets/pika-wordmark.svg" alt="Pika" width="260">
</p>

<p align="center">
  <a href="https://github.com/tekanic/pika/actions/workflows/ci.yml">
    <img src="https://github.com/tekanic/pika/actions/workflows/ci.yml/badge.svg" alt="CI">
  </a>
</p>

<img src="assets/pika-mascot.svg" alt="" width="180" align="right">

A Grape-inspired REST API framework for Crystal — declarative DSL, compile-time param validation, zero external dependencies.

```crystal
require "pika"

class MyAPI < Pika::API
  version "v1"

  resource :users do
    desc "Create a user"
    params do
      requires name  : String, regexp: /\A\w+\z/
      requires email : String
      optional role  : String = "member", values: %w[member admin]
    end
    post do
      {created: true, name: declared_params.name}.to_json
    end
  end
end

MyAPI.run  # 0.0.0.0:3000
```

---

## Features

- **Routing** — `resource`, `namespace`, `route_param`, `version`, `mount`; hand-rolled router on Crystal's stdlib `HTTP::Server`, zero external dependencies
- **Params** — `requires`/`optional` with type coercion (`String`, `Int32`, `Int64`, `Float64`, `Bool`, nilable variants); `regexp`, `values`, `length` constraints; `mutually_exclusive`, `at_least_one_of`, `exactly_one_of`; `params_from ModelClass` to derive params from a Clear model column schema
- **Hooks** — `before`/`after` blocks scoped per resource/namespace; errors raised in hooks are caught and formatted
- **Helpers** — `helpers` block for class-level helper methods callable directly from handlers
- **Entities** — `Pika::Entity(T)` with `pika_entity do...end` DSL; `expose :field`, conditional `expose :field, if: :flag`, computed `expose(:key) { |obj| expr }`; `present obj, using: EntityClass` in handlers
- **Errors** — `Pika::Error` hierarchy with pluggable formatters: `error_formatter :rfc7807` (default), `:grape`, `:jsonapi`
- **OpenAPI 3.1** — full spec via `MyAPI.openapi_doc`; `info title:, version:, description:` macro; `:param` → `{param}` path conversion; schemas derived from entity and param definitions
- **Scalar UI** — `docs at: "/docs"` mounts an interactive API explorer + JSON spec endpoint directly on the API router
- **Concurrency** — single-binary multi-thread via `--threads N` (`preview_mt`); multi-process horizontal scaling via `reuse_port: true` on `MyAPI.run`
- **Clear ORM bridge** — `pika-clear` shard (separate, versioned independently): auto-derives OpenAPI schemas, request validation, and entity exposure from `Clear::Model` column definitions
- **Authentication** — `pika-auth` shard (separate, versioned independently): Bearer token, API key, and HTTP Basic strategies with class-level defaults and per-resource overrides; failed auth raises `Pika::UnauthorizedError`

---

## Design principles

1. **DSL feel over DSL fidelity.** Grape parity is a guide, not a constraint. Where Crystal idioms suggest a better path — type annotations instead of `type: Integer`, structs instead of hashes — Pika takes the Crystal path.
2. **Macros over runtime metaprogramming.** Param validation, OpenAPI emission, and entity rendering are macro-expanded at compile time. There is no runtime reflection. A param typo is a compile error, not a 500.
3. **Errors are first-class.** The error contract is part of the API surface and is specified as carefully as success responses. Every error class maps to an HTTP status and a structured body; the format is pluggable.
4. **OpenAPI is not an afterthought.** Every DSL construct has a defined OpenAPI mapping. If something can be expressed in the DSL but not in the spec, that is a design bug, not a documentation gap.
5. **Opinionated defaults, escape hatches everywhere.** RFC 7807 by default — but pluggable. Path versioning by default — but extensible. JSON by default — but format-negotiable. You should never need to fork the framework to change a default.

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| [Crystal](https://crystal-lang.org/install/) | `>= 1.0.0` | Latest stable recommended |
| [Shards](https://github.com/crystal-lang/shards) | bundled with Crystal | Dependency manager |
| **For `pika-clear` only** | | |
| [PostgreSQL](https://www.postgresql.org/download/) | `>= 14` | Required by Clear ORM |
| **For running benchmarks only** | | |
| [bombardier](https://github.com/codesenberg/bombardier) | any | HTTP benchmarking tool |

Install Crystal via the official installer or your package manager:

```sh
# macOS
brew install crystal

# Ubuntu/Debian
curl -fsSL https://packagecloud.io/AtomEditor/crystal/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/crystal.gpg
```

Full platform-specific instructions at [crystal-lang.org/install](https://crystal-lang.org/install/).

---

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  pika:
    github: tekanic/pika
    version: "~> 0.1"
```

Then run `shards install`.

For the Clear ORM integration, also add `pika-clear`:

```yaml
dependencies:
  pika:
    github: tekanic/pika
  pika-clear:
    github: tekanic/pika-clear
```

For authentication strategies, also add `pika-auth`:

```yaml
dependencies:
  pika:
    github: tekanic/pika
  pika-auth:
    github: tekanic/pika-auth
```

---

## DSL overview

```crystal
require "pika"

class MyAPI < Pika::API
  info title: "My API", version: "1.0.0", description: "Example"
  version "v1"
  docs at: "/docs"  # mounts Scalar UI + /docs/openapi.json

  before do
    raise Pika::UnauthorizedError.new unless env.request.headers["X-Token"]? == ENV["API_TOKEN"]
  end

  helpers do
    def self.current_user(env) : String
      env.request.headers["X-User"]? || "anonymous"
    end
  end

  namespace :admin do
    resource :users do
      desc "List all users"
      get do
        {users: [], requested_by: self.current_user(env)}.to_json
      end

      desc "Create a user"
      params do
        requires name  : String, regexp: /\A\w+\z/
        requires email : String
        optional role  : String = "member", values: %w[member admin]
      end
      post do
        {created: true, name: declared_params.name}.to_json
      end

      route_param :id do
        desc "Get a user"
        get do
          {id: declared_params.id}.to_json
        end

        desc "Update a user"
        params do
          optional name : String?
          optional role : String?
          mutually_exclusive :name, :role
        end
        patch do
          {updated: true}.to_json
        end
      end
    end
  end

  resource :health do
    get do
      {status: "ok"}.to_json
    end
  end
end

MyAPI.run(port: 3000)
```

Routes registered:

```
GET    /v1/admin/users
POST   /v1/admin/users
GET    /v1/admin/users/:id
PATCH  /v1/admin/users/:id
GET    /v1/health
GET    /docs
GET    /docs/openapi.json
```

---

## Params

Params are declared with `requires` (mandatory) or `optional` (with optional default). Crystal types are coerced at request time; invalid params return 422 before your handler runs.

```crystal
params do
  requires id    : Int64
  requires name  : String, length: 1..100, regexp: /\A\w+\z/
  optional score : Float64 = 0.0
  optional tags  : String?, values: %w[a b c]

  mutually_exclusive :name, :email      # at most one
  at_least_one_of   :name, :email      # at least one
  exactly_one_of    :card, :bank       # exactly one
end
```

Inside handlers, params are accessed via `declared_params`:

```crystal
get do
  declared_params.name   # String — type-safe, no casting
  declared_params.score  # Float64
end
```

### Deriving params from a Clear model

```crystal
params_from User, only: [:name, :email, :role]
```

Reads `User::PIKA_COLUMNS` (generated by `pika-clear`) and creates `requires`/`optional` entries matching the column types. Nilable columns (`Int32?`, `String?`) become `optional` params; non-nilable columns become `requires`.

---

## DSL syntax notes

Pika uses Crystal's macro system to provide a declarative DSL. A few patterns look unusual compared to standard Crystal — here's why they work.

### `requires` and `optional` look like variable declarations

```crystal
params do
  requires name : String
  optional age  : Int32 = 0
end
```

These are macro calls, not variable declarations. `requires name : String` is a call to the `requires` macro with the argument `name : String`, which Crystal parses as a typed declaration node. Pika's macro inspects that node at compile time to extract the param name, type, and default value, then generates a typed struct and a validation method. No runtime reflection is involved.

### `declared_params` is a generated struct, not a hash

```crystal
declared_params.name   # String
declared_params.age    # Int32
```

Each `params` block generates a unique Crystal struct with typed properties. `declared_params` is an instance of that struct, populated and validated before your handler runs. Accessing a nonexistent field is a compile-time error, not a runtime `KeyError`.

### `expose` with a block uses a different call form

```crystal
pika_entity do
  expose :title                          # direct field access
  expose :slug, if: :admin              # conditional — only included when opts[:admin] is truthy
  expose(:display_name) { |u| u.name }  # computed — parentheses required when passing a block
end
```

The parenthesised form `expose(:key) { |obj| ... }` is needed when attaching a block in Crystal's macro call syntax. The bare form `expose :field` is shorthand for direct property access on the object.

### `self.` is required for helper methods inside handlers

```crystal
helpers do
  def self.current_user(env)
    env.request.headers["X-User"]? || "anonymous"
  end
end

resource :users do
  get do
    self.current_user(env)   # explicit self — bare `current_user(env)` may not resolve
  end
end
```

Handler blocks are expanded inside a class-level proc. Helper methods are defined as class methods (`def self.method`), so they require an explicit `self.` receiver inside the handler body.

### `present` uses a named `using:` argument

```crystal
present user, using: UserEntity
present users, using: UserEntity, admin: true   # extra kwargs forwarded to expose conditions
```

`present` is a class method with signature `def self.present(obj, using entity_class, **opts)`. The `using:` keyword is a named argument — it reads naturally as prose and matches Grape's convention. Extra keyword arguments are forwarded to the entity's `represent` call and become available as condition flags in `expose :field, if: :flag`.

---

## Entities

```crystal
class UserEntity < Pika::Entity(User)
  pika_entity do
    expose :id
    expose :name
    expose :email
    expose :role, if: :admin_view
    expose(:display_name) { |u| "#{u.name} <#{u.email}>" }
  end
end

# In a handler:
get do
  user = find_user(declared_params.id)
  present user, using: UserEntity, admin_view: self.current_user(env).admin?
end
```

---

## Error handling

Raise any `Pika::Error` subclass — Pika catches it and renders the appropriate HTTP status and body:

```crystal
raise Pika::UnauthorizedError.new           # 401
raise Pika::ForbiddenError.new              # 403
raise Pika::NotFoundError.new("No widget")  # 404
raise Pika::ConflictError.new               # 409
raise Pika::UnprocessableError.new("Bad")   # 422
```

Param validation failures return 422 with a structured `errors` array automatically.

Change the error format globally:

```crystal
class MyAPI < Pika::API
  error_formatter :jsonapi   # or :grape, :rfc7807 (default)
end
```

---

## OpenAPI 3.1

Pika generates a full OpenAPI 3.1 document from the same DSL used to define routes — no separate annotation layer, no decorator soup. Everything in the spec is derived directly from what's already in your code.

### What gets captured automatically

| DSL construct | OpenAPI output |
|---|---|
| `version "v1"` + `namespace`/`resource` | Path strings under `paths` |
| `route_param :id` | `{id}` path parameter with `in: path, required: true` |
| `desc "..."` | `summary` field on the operation |
| `requires name : String` | Required query parameter or request body field |
| `optional score : Float64` | Optional query parameter or request body field |
| `params` on `POST`/`PUT`/`PATCH` | `requestBody` with `application/json` schema |
| `params` on `GET`/`DELETE` | `parameters` array with `in: query` |
| `info title:, version:, description:` | `info` object in the document root |

Path parameters use `:name` in the router and are converted to `{name}` in the OpenAPI output automatically.

### Setting API metadata

```crystal
class MyAPI < Pika::API
  info title:       "Users API",
       version:     "1.0.0",
       description: "Manages user accounts and authentication"
end
```

If `info` is omitted, `title` defaults to the class name and `version` to `"1.0.0"`.

### Accessing the spec

```crystal
# Full OpenAPI 3.1 JSON document
MyAPI.openapi_doc   # => String (JSON)

# Just the paths object (useful for merging into a manually-built spec)
MyAPI.openapi       # => String (JSON)
```

### Serving the spec and Scalar UI

[Scalar](https://scalar.com) is a browser-based API reference UI. It renders your OpenAPI spec as an interactive explorer where you can read endpoint documentation, inspect request/response schemas, and send live test requests directly from the browser.

Enable it by adding `docs at:` to your API class:

```crystal
class MyAPI < Pika::API
  info title: "My API", version: "1.0.0"
  docs at: "/docs"
end

MyAPI.run
```

This mounts two routes on the running server:

| Route | What it serves |
|---|---|
| `GET /docs` | Scalar HTML UI — open this in a browser |
| `GET /docs/openapi.json` | Raw OpenAPI 3.1 JSON spec |

#### Viewing the docs

Start your server and navigate to the docs URL in any browser:

```sh
crystal run src/my_api.cr
# → open http://localhost:3000/docs
```

Scalar loads the spec from `/docs/openapi.json` at page load time, so the UI always reflects the currently running server. There is no build step, no static file generation, and no separate docs server to run.

#### What you can do in the UI

- **Browse endpoints** — all routes are listed in the left sidebar, grouped by resource
- **Read parameter docs** — required/optional params, types, constraints, and descriptions are shown per operation
- **Inspect request schemas** — `POST`/`PUT`/`PATCH` body schemas are rendered with field names and types
- **Send test requests** — each operation has a "Try" panel where you can fill in parameters and fire a real HTTP request against the running server, with the response shown inline

#### Path customisation

The `"/docs"` path is a default — pass any path prefix:

```crystal
docs at: "/api-reference"
# → GET /api-reference
# → GET /api-reference/openapi.json
```

#### CDN dependency

Scalar's JavaScript is loaded from jsDelivr (`cdn.jsdelivr.net`) at runtime. The browser serving `/docs` needs outbound internet access to render the UI. The JSON spec endpoint (`/docs/openapi.json`) has no external dependency and works fully offline.

For air-gapped or fully offline environments, fetch the spec from `/docs/openapi.json` and load it into any OpenAPI-compatible viewer (Swagger UI, Redoc, Stoplight Elements, etc.).

### Route descriptions

Use `desc` immediately before the HTTP verb to add a summary to an operation:

```crystal
resource :users do
  desc "List all users"
  get do ... end

  desc "Create a user"
  params do
    requires name  : String
    requires email : String
  end
  post do ... end

  route_param :id do
    desc "Get a user by ID"
    get do ... end

    desc "Delete a user"
    delete do ... end
  end
end
```

A `desc` without a following verb is silently dropped — it never causes an error.

### Example generated document

For the route definition above, `MyAPI.openapi_doc` produces:

```json
{
  "openapi": "3.1.0",
  "info": {
    "title": "Users API",
    "version": "1.0.0",
    "description": "Manages user accounts and authentication"
  },
  "paths": {
    "/v1/users": {
      "get": {
        "summary": "List all users",
        "operationId": "get_v1_users",
        "responses": { "200": { "description": "OK" } }
      },
      "post": {
        "summary": "Create a user",
        "operationId": "post_v1_users",
        "requestBody": {
          "required": true,
          "content": {
            "application/json": {
              "schema": {
                "type": "object",
                "required": ["name", "email"],
                "properties": {
                  "name":  { "type": "string" },
                  "email": { "type": "string" }
                }
              }
            }
          }
        },
        "responses": { "200": { "description": "OK" } }
      }
    },
    "/v1/users/{id}": {
      "get": {
        "summary": "Get a user by ID",
        "operationId": "get_v1_users_id",
        "parameters": [
          { "name": "id", "in": "path", "required": true, "schema": { "type": "string" } }
        ],
        "responses": { "200": { "description": "OK" } }
      },
      "delete": {
        "summary": "Delete a user",
        "operationId": "delete_v1_users_id",
        "parameters": [
          { "name": "id", "in": "path", "required": true, "schema": { "type": "string" } }
        ],
        "responses": { "200": { "description": "OK" } }
      }
    }
  }
}
```

### Mounted sub-APIs

When you `mount` a sub-API, its routes are merged into the parent's OpenAPI document automatically:

```crystal
class AdminAPI < Pika::API
  resource :reports do
    desc "List reports"
    get do ... end
  end
end

class MyAPI < Pika::API
  version "v1"
  info title: "Full API", version: "1.0.0"
  docs at: "/docs"

  mount AdminAPI   # /v1/reports appears in MyAPI.openapi_doc
end
```

---

## Versioning

Pika supports three strategies for communicating the API version.

### Path versioning (default)

The version becomes a URL prefix — the classic REST style.

```crystal
class MyAPI < Pika::API
  version "v1"          # equivalent to: version "v1", using: :path
  # → GET /v1/users
end
```

### Header versioning

Routes are registered at their bare path. The client sends `X-Api-Version`.

```crystal
class V1API < Pika::API
  version "v1", using: :header

  resource :users do
    get { "v1 users" }
  end
end

class V2API < Pika::API
  version "v2", using: :header

  resource :users do
    get { "v2 users" }
  end
end

class MyAPI < Pika::API
  mount V1API
  mount V2API
end
```

```
GET /users
X-Api-Version: v1
```

### Accept-header versioning

The version is encoded in the `Accept` media type using the vendor string.

```crystal
class V1API < Pika::API
  version "v1", using: :accept, vendor: "myapp"

  resource :users do
    get { "v1 users" }
  end
end
```

```
GET /users
Accept: application/vnd.myapp.v1+json
```

Both dot and hyphen separators are accepted (`vnd.myapp.v1+json` and `vnd.myapp-v1+json`).

### Multi-version apps

Mount versioned sub-APIs into a root app. Each sub-API declares its own version strategy independently.

```crystal
class MyAPI < Pika::API
  mount V1API
  mount V2API
end
```

Unversioned routes (no `version` call) always match regardless of any version header.

---

## Mounting sub-APIs

```crystal
class V2::UsersAPI < Pika::API
  resource :users do
    get do "v2 users" end
  end
end

class MyAPI < Pika::API
  version "v1"
  mount V2::UsersAPI
end
```

---

## Authentication (`pika-auth`)

`pika-auth` is a companion shard that adds pluggable authentication strategies to Pika. It is versioned and released independently so you only pull it in when you need it.

### What it provides

| Feature | Description |
|---|---|
| `BearerToken` | Reads `Authorization: Bearer <token>` and validates via a block |
| `ApiKey` | Reads from a configurable header (default `X-API-Key`) and/or query param |
| `Basic` | Reads `Authorization: Basic <base64(user:pass)>` and validates username + password |
| `auth :name do...end` | Sets a class-level default strategy for all routes |
| `public_resource :name do...end` | Marks a resource as open — no auth required |
| `resource_auth :name, :strategy do...end` | Overrides the strategy for a single resource |

### Setup

```crystal
# shard.yml
dependencies:
  pika:
    github: tekanic/pika
  pika-auth:
    github: tekanic/pika-auth
```

```crystal
require "pika"
require "pika-auth"
```

### Class-level auth

```crystal
class MyAPI < Pika::API
  include Pika::Auth

  auth :bearer do |token|
    token == ENV["API_TOKEN"]
  end

  resource :users do
    get { User.all.to_json }   # bearer required
  end
end
```

`include Pika::Auth` installs a `before` hook. The `auth` macro registers a named strategy and sets it as the class-level default.

### Per-resource overrides

```crystal
class MyAPI < Pika::API
  include Pika::Auth

  auth :bearer do |token|
    UserToken.valid?(token)
  end

  # No auth on this resource
  public_resource :health do
    get { {status: "ok"}.to_json }
  end

  # Different strategy on this resource
  resource_auth :webhooks, :api_key do |key|
    key == ENV["WEBHOOK_SECRET"]
  end do
    post { handle_webhook }
  end

  resource :users do
    get { User.all.to_json }   # bearer (class default)
  end
end
```

| Path | Strategy |
|---|---|
| `GET /health` | none (public) |
| `GET /users` | bearer (class default) |
| `POST /webhooks` | api_key (per-resource) |

All three strategies raise `Pika::UnauthorizedError` on failure, which Pika converts to `401 Unauthorized`.

See [tekanic/pika-auth](https://github.com/tekanic/pika-auth) for full documentation.

---

## Clear ORM integration (`pika-clear`)

`pika-clear` is a companion shard that bridges Pika and [Clear](https://github.com/anykeyh/clear), a PostgreSQL ORM for Crystal. It is versioned and released independently from Pika's core so that neither shard forces you to adopt the other.

### What it provides

| Feature | Description |
|---|---|
| `Pika::Clear::Model` | Mixin that generates a `PIKA_COLUMNS` compile-time constant from Clear column annotations |
| `expose_clear_model` | Entity macro that derives field exposure directly from `PIKA_COLUMNS` |
| `params_from ModelClass` | Derives a `params` block from a model's column schema |
| `paginate` | Applies `page`/`per_page` to a Clear query and returns `{"data":[...],"meta":{...}}` |
| `Pika::ValidationError.from_clear_model` | Converts Clear model validation errors into Pika 422 responses |
| `Pika::Clear.map_db_error` | Maps database exceptions (unique violation, FK error, etc.) to Pika error classes |

### Setup

```crystal
# shard.yml
dependencies:
  pika:
    github: tekanic/pika
  pika-clear:
    github: tekanic/pika-clear
```

```crystal
require "pika"
require "pika-clear"
```

### Model setup

Include both `Clear::Model` and `Pika::Clear::Model` in your model. The `Pika::Clear::Model` mixin inspects `@[Clear::Column]`-annotated instance variables at compile time (via `macro finished`) and generates a `PIKA_COLUMNS` constant that the rest of pika-clear reads.

```crystal
class User
  include Clear::Model
  include Pika::Clear::Model

  self.table = "users"

  column id    : Int64,   primary: true
  column email : String
  column name  : String
  column age   : Int32?   # nilable → becomes optional param
  column role  : String
  timestamps
end
```

### Entities with `expose_clear_model`

Instead of listing every column manually in `pika_entity`, use `expose_clear_model` to derive the field list from the model schema. Columns in `except:` are excluded.

```crystal
class UserEntity < Pika::Entity(User)
  expose_clear_model User, except: [:role]
  # role is still accessible but not exposed unless you add it manually:
  # expose :role, if: :admin_view
end
```

`expose_clear_model` generates both `represent(obj)` and `represent(collection)` methods, so the entity works for single objects and arrays.

### Request validation with `params_from`

`params_from` reads `PIKA_COLUMNS` and synthesises a `params` block — non-nilable columns become `requires`, nilable columns become `optional`. Use `only:` or `except:` to limit the fields.

```crystal
resource :users do
  desc "Create a user"
  params_from User, except: [:id, :created_at, :updated_at]
  post do
    user = User.new
    user.email = declared_params.email
    user.name  = declared_params.name
    user.age   = declared_params.age    # Int32? — may be nil
    user.save!
    present user, using: UserEntity
  end
end
```

### Pagination

`paginate` wraps a Clear query scope with `LIMIT`/`OFFSET` and returns a standard JSON envelope.

```crystal
resource :users do
  params do
    optional page     : Int32 = 1
    optional per_page : Int32 = 25
  end
  get do
    paginate(User.query, using: UserEntity,
             page: declared_params.page,
             per_page: declared_params.per_page)
  end
end
```

Response shape:

```json
{
  "data": [...],
  "meta": { "total": 120, "page": 2, "per_page": 25, "pages": 5 }
}
```

### Error mapping

```crystal
post do
  user = User.build(declared_params)
  unless user.valid?
    raise Pika::ValidationError.from_clear_model(user)  # → 422 with errors array
  end
  user.save!
rescue e : Exception
  raise Pika::Clear.map_db_error(e)  # unique violation → 409, FK error → 422, etc.
end
```

---

## Concurrency & scaling

```crystal
# Multi-threaded (compile with -Dpreview_mt)
MyAPI.run(port: 3000)

# Multi-process horizontal scaling — each process shares the port via SO_REUSEPORT
MyAPI.run(port: 3000, reuse_port: true)
```

Compile with `--threads N` for the multi-threaded build. For multi-process, spawn `N` copies with `reuse_port: true`; the OS load-balances across them.

---

## Performance

Measured with `bombardier -c 128 -d 15s` on Apple M-series. No external HTTP dependency — Pika owns its router.

| Mode | Static route | JSON response | Validated params |
|---|---|---|---|
| Single-threaded (`--release`) | 155,719 req/s | 142,126 req/s | 123,121 req/s |
| `--threads 4` (`preview_mt`) | 190,098 req/s | 166,117 req/s | 145,715 req/s |
| 4× processes (`reuse_port`) | 153,300 req/s | 145,029 req/s | 135,396 req/s |

Full numbers and methodology: [`bench/results.md`](bench/results.md).

---

## Development

```sh
crystal spec              # run the spec suite
crystal spec --error-trace  # with backtraces
```

---

## Migrating from Grape

If you're coming from Ruby's Grape, most concepts map directly. The main differences are Crystal's type system (annotations instead of `type:` options) and a few naming choices.

### Param declarations

```ruby
# Grape
params do
  requires :name,  type: String
  requires :age,   type: Integer
  optional :role,  type: String, default: "member", values: %w[member admin]
end
```

```crystal
# Pika
params do
  requires name : String
  requires age  : Int32
  optional role : String = "member", values: %w[member admin]
end
```

Crystal's type annotation syntax replaces Grape's `type:` option. Nilable types (`String?`) replace `allow_blank: true`.

### Accessing params

```ruby
# Grape — returns a hash
params[:name]
declared(params)[:name]
```

```crystal
# Pika — returns a typed struct, compile-time checked
declared_params.name   # String, no casting needed
```

### Presenting responses

```ruby
# Grape
present user, with: API::Entities::User
```

```crystal
# Pika — same concept, `using:` instead of `with:`
present user, using: UserEntity
```

### Errors

```ruby
# Grape
error!("Unauthorized", 401)
error!({ message: "Not found" }, 404)
```

```crystal
# Pika — raise typed error classes
raise Pika::UnauthorizedError.new
raise Pika::NotFoundError.new("Not found")
```

### Before/after hooks

```ruby
# Grape — implicit access to `params` and `request`
before do
  authenticate!
end
```

```crystal
# Pika — `env` is the explicit HTTP context
before do |env|
  raise Pika::UnauthorizedError.new unless valid_token?(env)
end
```

### Mounting

```ruby
# Grape — path specified at mount site
mount V2::UsersAPI => "/v2"
```

```crystal
# Pika — sub-API owns its own version/path; no path arg at mount
mount V2::UsersAPI
```

### Quick reference

| Grape | Pika | Notes |
|---|---|---|
| `requires :name, type: String` | `requires name : String` | Crystal type annotation |
| `optional :age, type: Integer, default: 0` | `optional age : Int32 = 0` | Default inline |
| `params[:name]` | `declared_params.name` | Typed struct, not hash |
| `present obj, with: Entity` | `present obj, using: Entity` | `using:` keyword |
| `error!("msg", 422)` | `raise Pika::UnprocessableError.new("msg")` | Typed errors |
| `mount API => "/path"` | `mount API` | Path set on the sub-API |
| `before { ... }` | `before do \|env\| ... end` | Explicit env |
| `helpers { def foo; end }` | `helpers do; def self.foo; end; end` | Class methods |
| `use SomeMiddleware` | Crystal `HTTP::Handler` chain | Not framework-level |
| `route_param :id` | `route_param :id do` | Same concept |
| `namespace :v1` | `namespace :v1` | Identical |
| `resource :users` | `resource :users` | Identical |
| `version "v1", using: :path` | `version "v1"` | Default strategy |
| `version "v1", using: :header` | `version "v1", using: :header` | `X-Api-Version` header |
| `version "v1", using: :accept_version_header` | `version "v1", using: :accept, vendor: "app"` | Vendor media type |

### What Pika does not have (yet)

- **XML/MessagePack formatters** — JSON only; planned for v0.9.
- **`use` middleware** — compose at the `HTTP::Server` level instead; Pika exposes a standard `HTTP::Handler`.
- **Built-in ORM integration** — use `pika-clear` for Clear, or write a before hook for any other ORM.

---

## Roadmap

| Milestone | Status |
|---|---|
| PoC gate (params, OpenAPI, perf) | ✅ complete |
| v0.1 — skeleton, router, basic DSL | ✅ complete |
| v0.2 — full DSL, hooks, error hierarchy | ✅ complete |
| v0.3 — entity layer, `mount`, formatters | ✅ complete |
| v0.4 — OpenAPI 3.1, Scalar UI, CI | ✅ complete |
| v0.5 — Clear ORM integration (`pika-clear` shard) | ✅ complete |
| v0.6 — benchmarks, `reuse_port`, `params_from` | ✅ complete |
| v0.7 — authentication strategies (`pika-auth` shard) | ✅ complete |
| v0.8 — header and Accept-header versioning | ✅ complete |
| v0.9 — XML and MessagePack response formatters | planned |
| v0.10 — async/streaming responses | planned |
| v1.0 — API freeze, docs site, launch | planned |

---

## Attribution

Pika is heavily inspired by [Grape](https://github.com/ruby-grape/grape), the REST-like API framework for Ruby. The core DSL concepts — `resource`, `namespace`, `route_param`, `params`/`requires`/`optional`, `before`/`after` hooks, `helpers`, `mount`, and the entity layer — are direct adaptations of Grape's design to Crystal's type system and macro capabilities. If you've built APIs with Grape, Pika should feel immediately familiar.

---

## Contributing

Bug reports and pull requests are welcome on GitHub at [tekanic/pika](https://github.com/tekanic/pika).

## License

MIT
