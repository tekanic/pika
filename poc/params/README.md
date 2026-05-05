# PoC 1: Params DSL Macro — PASSED ✅

**Goal:** prove Crystal macros can parse and generate working code for the Crystal-native params syntax.

## Run

```sh
crystal poc/params/params_poc.cr
```

## Success criteria

- [x] Macro parses hybrid syntax (type annotations + keyword args) without error
- [x] Generated `DeclaredParams` struct has correctly-typed fields
- [x] Validation method accepts valid inputs and rejects invalid ones
- [x] Error messages are reasonable (field name, constraint violated)
- [x] Compile time acceptable — no measurable issue at PoC scale

## Key findings

**Block body must be parsed as AST, not via sub-macro dispatch.**
The `{{ block.body }}` + class-accumulator pattern fails: Crystal's `{% %}` control flow runs before child macro calls from `{{ block.body }}` are expanded, so the accumulator is always empty. Correct pattern: `{% for expr in block.body.expressions %}` inside the `params` macro itself — extract type declarations directly from AST nodes.

**`decl.value` is `Nop` (not `nil`) for declarations without a default.**
Guard: `unless decl.value.is_a?(Nop)`, not `unless decl.value == nil`.

**Named arg keys are `StringLiteral`, not `Symbol`.**
Match with `na.name == "regexp"` (string equality). Hash lookup with symbol key returns `NilLiteral` and silently drops constraints.

**`Call#name` returns `MacroId`, not `StringLiteral`.**
`{{ expr.name }}` emits a bare identifier. Call `.stringify` before storing if the value will be interpolated as a quoted string later.

**Constraints must guard on raw value presence.**
`values`, `length`, `regexp` constraints should only validate user-provided values — not default values — to avoid confusing errors.

## Recommendation

**Proceed as designed.** The block-body AST parse is the correct Crystal idiom. No fallback to Grape-style symbol syntax needed.
