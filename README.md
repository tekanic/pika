# Pika

[![CI](https://github.com/tekanic/pika/actions/workflows/ci.yml/badge.svg)](https://github.com/tekanic/pika/actions/workflows/ci.yml)

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

Reads `User::PIKA_COLUMNS` (generated by `pika-clear`) and creates `requires`/`optional` entries matching the column types.

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
| v1.0 — API freeze, docs site, launch | planned |

---

## Contributing

Bug reports and pull requests are welcome on GitHub at [tekanic/pika](https://github.com/tekanic/pika).

## License

MIT
