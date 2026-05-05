# PoC 2: OpenAPI Emission via Macro Metadata Accumulation — PASSED ✅

**Goal:** prove that metadata accumulated across desc/params/verb calls can be emitted as a valid OpenAPI 3.1 paths fragment at compile time.

## Run

```sh
crystal poc/openapi/openapi_poc.cr
```

## Success criteria

- [x] desc/params/verb triples correctly associated per route
- [x] Generated OpenAPI JSON is structurally valid
- [x] Path parameters extracted from route patterns and typed as `"string"`
- [x] Request body schemas derived from params blocks
- [x] Required vs optional fields correct
- [x] Routes without bodies emit no `requestBody`

## Key findings

**Cross-call state accumulation at class level does not work reliably.**
Crystal macros cannot share mutable state between sequential, independent macro calls (`desc`, `params`, `get` as separate class-level statements). Class constants can be pushed to but not reassigned between calls, and there is no post-class-body hook.

**Working pattern: context macro block.**
All route definitions live inside a context macro (`routes do...end`, `resource :users do...end`, etc.). The macro parses its block body as AST, extracts desc/params/verb triples using macro-local variables (`pending_desc`, `pending_body`, `route_list`), and generates all route code and OpenAPI metadata in a single expansion pass. This is the same block-body AST parse proven in PoC 1.

**Architectural implication.**
In practice, Grape's DSL is also always nested inside `resource`/`namespace` blocks. Pika's design — all routes inside context macros — maps cleanly to this usage pattern. Flat top-level syntax (routes defined directly on the class body without a wrapper) is not needed.

**Additional macro rules confirmed:**
- `ArrayLiteral#includes?` does not work in `{% %}` context — use explicit `||` chains
- `StringLiteral#gsub` requires a `Regex` first argument, not a `String`
- `{% if %}...{% end %}` inline in named argument position generates stray newlines — emit duplicate full code blocks (one per branch) instead
- `Call#name` is `MacroId` — call `.stringify` before storing for later string interpolation

## Sample output

```json
{
  "/users/:id": {
    "get": {
      "summary": "Get a user",
      "parameters": [{"name": "id", "in": "path", "required": true, "schema": {"type": "string"}}]
    }
  },
  "/users": {
    "post": {
      "summary": "Create a user",
      "requestBody": {
        "required": true,
        "content": {
          "application/json": {
            "schema": {
              "type": "object",
              "required": ["email", "name"],
              "properties": {
                "email": {"type": "string"},
                "name": {"type": "string"},
                "age": {"type": "integer"}
              }
            }
          }
        }
      }
    }
  }
}
```

## Recommendation

**Proceed with design adjustment.** Context-macro-block is the canonical pattern. `Pika::API` class body (or explicit `routes do...end`) is the outermost context; `resource`/`namespace` macros nest inside using the same approach.
