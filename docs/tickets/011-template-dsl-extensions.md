# RFC-011: Source Generator Template DSL Extensions

**Type:** Source generator language extension
**Status:** Proposed
**Depends on:** None

## Summary

Extend the source-generator template DSL with three constructs:

- **`#elif cond { }`** — chain conditionals without nesting `#else { #if ... }`.
- **`#let name = expr`** — bind template-time values for reuse in subsequent template expressions.
- **`#match expr { Pattern => { ... }, ... }`** — pattern dispatch on template-time values, particularly useful for branching on a `Type` parameter's kind or an enum's variant shape.

The DSL stays bounded — not Turing-complete — and relies on the existing 8-round expansion limit ([spec.md:544](../spec.md:544)) for compositional generators.

## Motivation

Today's template DSL is `#(expr)` interpolation, `#for var in collection`, `#if cond { } #else { }` ([spec.md:528](../spec.md:528)). For built-in generators like `#derive(eq)` on a struct with many fields, the lack of `#let` forces inline re-computation; the lack of `#elif` forces deeply nested `#if`/`#else` chains; the lack of `#match` makes branching on type kind awkward.

These are type-level operations, not general programming. The right level of expressiveness is "enough to mechanically generate code from type metadata" — not "build arbitrary algorithms."

## Design

### `#elif`

```
#if T.is_struct {
    /* struct-specific generation */
} #elif T.is_enum {
    /* enum-specific generation */
} #elif T.is_primitive {
    /* primitive-specific generation */
} #else {
    /* fallback */
}
```

- Sugar for nested `#else { #if ... }`.
- Same evaluation: only the first matching branch's body is emitted.
- Chain length unbounded.

### `#let`

```
#let fields = T.fields
#let n_fields = fields.len
#for f in fields {
    #(f.name): #(f.type),
}
```

- Binds a template-time value to a name. Scoped to the enclosing `#define` block (or the enclosing `#if`/`#for`/`#match` body).
- Once bound, immutable — no `#let x = x + 1`. Iteration covers the mutable-counter case.
- Value can be any template-DSL type (`Type`, `Ident`, `Int`, `String`, `List(T)`, `Field`, `Variant`, etc.).

### `#match`

```
#match T {
    Struct => {
        /* T is a struct — emit struct-specific code */
    }
    Enum => {
        /* T is an enum — emit enum-specific code */
    }
    Primitive(name) => {
        /* T is a primitive — `name` bound to its name */
    }
    else => {
        /* fallback */
    }
}
```

- Same arm syntax as runtime `match` (RFC-006 §5: `pattern => { body }`, no commas, brace-mandatory).
- Patterns: type-kind tags (`Struct`, `Enum`, `Primitive`, `Slice`, `Reference`, `Function`, etc.), variant matching for richer types like `Field` (`Field { name, type }`), wildcard `_`, `else`.
- Pattern grammar is a subset of runtime patterns (RFC-010): unit-variant, payload-binding, struct destructuring, wildcard, `else`. No or-patterns or guards in templates (defer if needed).

### Template-time value model

The DSL operates on a fixed set of types. Defined precisely so generator authors can rely on what's available:

| Type | Description | Methods/fields |
|---|---|---|
| `Type` | Reflection on a FLang type | `.name`, `.kind`, `.fields`, `.variants`, `.is_struct`, `.is_enum`, `.is_primitive`, `.size_of`, `.align_of` |
| `Ident` | A bare identifier | `.text` |
| `Field` | A struct field | `.name: Ident`, `.type: Type` |
| `Variant` | An enum variant | `.name: Ident`, `.payload_types: List(Type)`, `.is_unit`, `.is_payload_carrying` |
| `Int` | Template-time integer | basic arithmetic, comparison |
| `String` | Template-time string literal | `.len`, basic concatenation |
| `List(T)` | Generic list | `.len`, `.is_empty`, indexing, iteration |

This is a closed set. Adding to it requires another RFC.

### Evaluation model

- Templates expand at compile time, before type resolution of the *generated* code (but after type resolution of the *generator's parameters*).
- `#define` body is parsed once into an AST; expansion walks the AST with a binding environment.
- 8-round expansion limit unchanged ([spec.md:544](../spec.md:544)).
- Direct in-template recursion (a generator calling itself in its body) remains forbidden. Use the multi-round expansion path: emit a call to another generator (or itself) into the output.

### Whitespace and comments

Unchanged from current behavior:
- Whitespace in template segments is preserved verbatim.
- `#(expr)` substitutes token text with no added whitespace.
- `//` line comments inside template bodies are stripped at template time (not emitted).

## Migration

Additive. Existing generators (`#derive`, `#enum_utils`, `#interface`, `#implement`) keep working. They can be rewritten to use `#let`/`#elif`/`#match` for clarity but aren't forced to.

## Implementation phases

1. **`#elif`.** Smallest. Just sugar over nested `#else { #if ... }` — implement at the parser level by lowering to the nested form, or directly in the template evaluator.
2. **`#let`.** Add binding-environment support to the template evaluator.
3. **Template-time value model.** Settle the closed type set; implement reflection methods on `Type` (most of these likely already exist somewhere in the type checker or LSP — wire them up).
4. **`#match`.** Pattern grammar in the template parser; dispatch in the evaluator.
5. **Refactor built-in generators** (`#derive`, `#enum_utils`) to use the new constructs where they simplify the implementation.

## Out of scope

- Full Turing-completeness in templates. Explicitly rejected.
- User-defined template-time helper functions. Out of scope; templates remain inline.
- Template-time mutation (`#let` is immutable). Out of scope.
- Adding new types to the value model beyond what's listed. Future RFC if needed.

## Open questions

1. **`Type.fields` for non-struct types.** Returns empty list, or error? Recommendation: empty list for non-structs; error only on truly invalid operations.
2. **Pattern grammar in `#match`.** Should it support runtime-pattern features like or-patterns and guards (RFC-010)? Recommendation: not initially. The template patterns are simpler — just kind dispatch and variant binding.
3. **Quoting raw FLang code in templates.** Today everything between `#define` braces is template body. Is there ever a need for a "raw" segment that doesn't process template directives? Recommendation: not now; if a generator needs a literal `#`, escape with `##`.
4. **Diagnostics for template errors.** When a template emits broken code, the type checker error points at the generated file. Should errors be back-mapped to the template source line? Important for usability but a separate piece of work.
