# RFC-008: Single Declaration Form for Structs and Enums

**Type:** Syntax / parser change + project-wide migration
**Status:** Proposed
**Depends on:** None

## Summary

Remove the legacy `struct Name(T) { ... }` and `enum Name { ... }` declaration forms. The single valid declaration form becomes:

```
type Name = struct(T) { fields... }
type Name = enum(T) { variants... }
```

Type aliases for non-struct/enum types remain unchanged: `type Index = usize`, `type Bytes = u8[]`, `type Callback = fn(i32) i32`.

## Motivation

FLang today supports two ways to declare a struct or enum:

```
struct Pair(T) { first: T, second: T }            // form 1: legacy
type Vec2 = struct { x: f32, y: f32 }             // form 2: alias-of-anon
type Option = struct(T) { has_value: bool, ... }  // form 2 with generics on `struct` keyword
```

Both work. Examples and stdlib mix the two. Costs:

1. **Two parser paths to maintain.** Each path has its own bug surface.
2. **Two ways for users to learn the same thing.** Code-review nits on which form to prefer.
3. **Generic-position asymmetry.** Form 1 puts `(T)` on the *name*; form 2 puts it on the *struct keyword*. Same use-site syntax (`Pair(i32)`, `Option(i32)`), different declaration shapes.
4. **Directives compose better in form 2.** `type Color = #foreign struct { ... }` reads naturally; `#foreign struct Color { ... }` (the form-1 equivalent) requires extra parser machinery to attach a directive to a `struct` declaration.

Form 2 is the canonical winner because it composes with directives, treats `struct` / `enum` uniformly as type-builders, and matches the existing `#foreign` / `#simd` inline syntax that's already in use.

## Design

### Allowed forms after migration

```
// Struct
type Point = struct {
    x: i32,
    y: i32,
}

// Generic struct
type Pair = struct(T) {
    first: T,
    second: T,
}

// Struct with directive
type Color = #foreign struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
}

type Vec128 = #simd struct {
    _data: [u8; 16],
}

// Enum
type Color = enum {
    Red,
    Green,
    Blue,
}

// Generic enum
type Result = enum(T, E) {
    Ok(T),
    Err(E),
}

// Bare enum (C-style)
type Ord = enum {
    Less = -1,
    Equal = 0,
    Greater = 1,
}

// Pure aliases (unchanged)
type Index = usize
type Bytes = u8[]
type Callback = fn(i32) i32
```

### Rejected forms

```
struct Pair(T) { ... }           // E20XX: rewrite as `type Pair = struct(T) { ... }`
struct Point { ... }             // E20XX: rewrite as `type Point = struct { ... }`
enum Color { ... }               // E20XX: rewrite as `type Color = enum { ... }`
#foreign struct Color { ... }    // E20XX: rewrite as `type Color = #foreign struct { ... }`
```

### Parser

- Remove the `struct <Ident>` and `enum <Ident>` declaration paths from the top-level statement parser.
- `struct` and `enum` keywords remain valid only:
  - As RHS of a `type` alias.
  - Inside source-generator argument positions ([Parser.cs:687](../../src/FLang.Frontend/Parser.cs:687)) — unchanged.
- Add a clear migration error pointing to the new form.

### Type checker

- The internal representation of declarations doesn't need to change — `type X = struct {...}` already produces a named struct type. Just funnel form-1 declarations through the same path during the deprecation period if you want a graceful rollover.

## Migration

This touches every `struct`/`enum` declaration in the codebase.

### Stdlib

Sweep `std/` and `core/` for form-1 declarations. Rewrite mechanically:
- `struct Name { ... }` → `type Name = struct { ... }`
- `struct Name(T) { ... }` → `type Name = struct(T) { ... }`
- `enum Name { ... }` → `type Name = enum { ... }`
- `enum Name(T) { ... }` → `type Name = enum(T) { ... }`

### Examples

Same sweep across all `examples/*/src/*.f`.

### Spec

- §2.4 (Structs): rewrite all examples in form 2.
- §2.5 (Enums): same.
- §2.7 (Option), §2.8 (Result): use form 2.
- Remove "alternative syntax" framing — form 2 is the only syntax.

### Tests

Audit `tests/FLang.Tests/Harness/` for any test fixtures using form 1; rewrite.

## Tooling

A simple regex-based migration script handles most cases:

```
struct (\w+)(\([^)]*\))? \{   →   type \1 = struct\2 {
enum (\w+)(\([^)]*\))? \{     →   type \1 = enum\2 {
```

Manual review for edge cases (multi-line declarations, declarations with directives).

## Out of scope

- Implementing form-2-with-directive cases not yet supported (e.g., `#derive` on the type declaration — that's a separate question about whether `#derive` attaches inline or stands alone).
- The Option-to-enum change (RFC-007) intersects with this — `Option` will be rewritten as `type Option = enum(T) { Some(T), None }` once both this RFC and RFC-007 land.

## Open questions

1. **Order with RFC-007.** Does Option migrate to enum (RFC-007) before or after this RFC? Either order works:
   - This first: `Option` is still a struct, but rewritten to form 2 (`type Option = struct(T) { ... }`). RFC-007 then changes `struct` to `enum`.
   - RFC-007 first: `Option` becomes an enum, declared in form 1 (`enum Option(T) { ... }`). This RFC then rewrites it to form 2.
   - Recommendation: this RFC first (mechanical sweep), then RFC-007 (semantic change). Less risky.
2. **`#derive` and other generators on the type declaration line.** Today `#derive(Vector2, eq, ...)` is a separate statement after the struct declaration. Should it move inline into the type alias? Out of scope; addressed separately if at all.
