# Pika

A Grape-inspired REST API framework for Crystal — declarative DSL, compile-time param validation, zero external dependencies.

> **Status:** v0.4 complete — full OpenAPI 3.1 docs, Scalar UI, CI. Next: v0.5 Clear ORM integration.

---

## Features (v0.4)

- **Routing** — `resource`, `namespace`, `route_param`, `version`, `mount`; hand-rolled router on stdlib `HTTP::Server`
- **Params** — `requires`/`optional` with type coercion (`String`, `Int32`, `Int64`, `Float64`, `Bool`, nilable variants); `regexp`, `values`, `length` constraints; `mutually_exclusive`, `at_least_one_of`, `exactly_one_of`
- **Hooks** — `before`/`after` blocks; errors raised in hooks are caught and formatted
- **Helpers** — `helpers` block for class-level helper methods callable from handlers
- **Entities** — `Pika::Entity(T)` with `pika_entity do...end` DSL; `expose :field`, `expose :field, if: :flag`, `expose(:key) { |obj| expr }`; `present obj, using: EntityClass` in handlers
- **Errors** — `Pika::Error` hierarchy with pluggable formatters: `error_formatter :rfc7807` (default), `:grape`, `:jsonapi`
- **OpenAPI 3.1** — full document via `MyAPI.openapi_doc`; `info title:, version:, description:` macro; `:param` → `{param}` path conversion
- **Scalar UI** — `docs at: "/docs"` mounts interactive docs + JSON spec endpoint on the API router

---

## Quick start

```sh
crystal spec   # 72 examples, 0 failures
```

---

## DSL overview

```crystal
require "pika"

class MyAPI < Pika::API
  version "v1"

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
        {users: [], requested_by: current_user(env)}.to_json
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
      "ok"
    end
  end
end

MyAPI.run  # listens on 0.0.0.0:3000
```

Routes registered:

```
GET  /v1/admin/users
POST /v1/admin/users
GET  /v1/admin/users/:id
PATCH /v1/admin/users/:id
GET  /v1/health
```

---

## Error handling

Raise any `Pika::Error` subclass from a handler or hook — Pika catches it and renders RFC 7807 JSON automatically:

```crystal
raise Pika::UnauthorizedError.new          # 401
raise Pika::NotFoundError.new("No widget") # 404
raise Pika::ForbiddenError.new             # 403
raise Pika::ConflictError.new              # 409
```

Param validation failures return 422 with a structured `errors` array.

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
| v0.6 — benchmarks (single/multi-thread/multi-process), polish | ✅ complete |
| v1.0 — API freeze, docs, launch | planned |

---

## Performance (v0.6, full DSL stack)

Measured with `bombardier -c 128 -d 15s` on Apple M-series. No Kemal dependency — Pika owns its router.

| Mode | Static route | JSON response | Validated params |
|---|---|---|---|
| Single-threaded (`--release`) | 155,719 req/s | 142,126 req/s | 123,121 req/s |
| `--threads 4` (`preview_mt`) | 190,098 req/s | 166,117 req/s | 145,715 req/s |
| 4× processes (`reuse_port`) | 153,300 req/s | 145,029 req/s | 135,396 req/s |

See [`bench/results.md`](bench/results.md) for full numbers and analysis.
