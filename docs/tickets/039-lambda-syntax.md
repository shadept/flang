---
status: implemented
type: language
created: 2026-10-17
implemented: 2026-10-18
relates: [RFC-014, RFC-033, RFC-035, RFC-037, RFC-038]
---

# RFC-039: Lambda syntax

## Summary

A lambda is a brace block with its parameters before `=>`, the arrow match arms use. A lambda
passed last can follow the call, and a one-parameter lambda can leave the parameter unnamed as
`it`:

```flang
xs.map { it * 2 }
xs.fold(0i32) { acc, x => acc + x }
with_c_path(path) { p =>
    let err: i32 = 0
    check(__flang_fs_rename(p, to, &err), err)
}
s.sort({ a, b => b.cmp(a) })
```

Trailing lambdas and named construction (`Point { x = 1 }`) share the `name {` shape. They are
told apart by the case of the name, which becomes a rule: types start uppercase, functions
lowercase.

This RFC is syntax only. Captures (RFC-033), closure lowering (RFC-014) and function values
(RFC-037) are unchanged; generic lambdas get their semantics in a later RFC.

## Motivation

- **`fn(x: T) R { ... }` repeats a declaration** for what is usually one expression. The compiler
  and stdlib hold 100 lambdas (34 in code, 66 in stdlib tests) and the harness 81 more.
- **Annotations the bounds already give.** Callbacks are bounded (`F: fn(&u8) Result(T, FsError)`,
  `F: fn(&Encoder)`), yet 53 of the 100 annotate their parameters and 44 spell out a return type.
- **Callbacks are last.** 97 of the 100 sit in the last argument position, most of them
  multi-line bodies in the stdlib (`with_c_path`, `send`, `rollback`), where the closing `})`
  trails the body.

## Design

### Lambda literal

```
{ x => x * 2 }               // one parameter
{ acc, x => acc + x }        // several
{ p: &u8 => ... }            // annotated; x: T, x: &T, x: move T, x: $T
{ => count += 1 }            // no parameters
{ it * 2 }                   // arrow-less (see below)
```

- Parameters take the forms function parameters take, without defaults or variadics.
- The body is a block: statements, then an optional trailing expression that is its value.
  `return` inside a lambda is an error (E1054, amended 2026-10-18): inside braces it reads as
  leaving the enclosing function. `break` and `continue` cannot reach a loop outside the lambda.
- **No return-type slot.** The return type comes from the bound or the expected function type,
  else from the body. Where nothing pins it, annotate the binding:
  `const f: fn(i32) i32 = { x => x + 1 }`.

### Where a brace is a lambda

- **In argument position** (inside a call's parentheses) and **in trailing position** (below), a
  `{` always opens a lambda. No call in the compiler or stdlib passes a block expression as an
  argument today.
- **Elsewhere** a `{` opens a lambda when the next tokens are `=>`, `ident =>`, `ident ,` or
  `ident :`, none of which can start a block; otherwise it is a block. The two tokens after the brace
  decide (`peek_kind(1)`, `peek_kind(2)`): fixed lookahead, no backtracking, no name lookup.
- So an arrow-less lambda appears only where a callable is expected by position: as an argument
  or trailing.

### Arrow-less lambdas and `it`

A lambda with no `=>` takes its arity from the callable expected at its position: none, or one,
named `it`. Expected arity above one is an error that asks for named parameters.

- `it` is not a keyword. It names the parameter only inside an arrow-less lambda, shadowing any
  outer `it`. 140 bindings in the compiler and stdlib are iterators named `it`; they keep working,
  and inside an arrow-less lambda in their scope `it` is the lambda's parameter.
- A nested arrow-less lambda's `it` shadows the enclosing one's. Name the parameters to reach
  both.

### Trailing lambdas

```
spawn { work() }                         // name {
with_c_path(path) { p => ... }           // name(args) {
xs.map { it * 2 }                        // .name {
xs.fold(0i32) { a, b => a + b }          // .name(args) {
self.on_event { log(it) }                // a callable field, through op_call
```

- A `{` on the same line as a lowercase name, or the `)` of a call through one, opens a trailing
  lambda. The parentheses may be omitted when the lambda is the only argument.
- **Binding.** The trailing lambda fills the last callable parameter: a `fn(...)` type or a type
  parameter bounded by one. Every parameter after it must have a default, so
  `xs.map(f, allocator = null)` takes `xs.map { ... }`. The parenthesized arguments fill the other
  parameters as usual. A callback parameter must therefore state its shape as a bound; the
  unbounded `$F` callbacks left in the container utilities gain theirs.
- **Headers.** In an `if`, `while` or `for` header the `{` at the header's level opens the body,
  as today; a trailing lambda there is parenthesized: `if (xs.any { it > 0 }) { ... }`.

### The case rule

A trailing lambda and named construction differ only in the name before `{`:

```
Point { x = 1 }                // Upper {       construction
Pair(i32) { first = 1 }        // Upper(...) {  construction
spawn { work() }               // lower {       trailing lambda
```

The parser decides by the name's first character. For that to hold, case is part of the
language:

- A user-declared type (struct, enum, alias, contract) and a type parameter start with an
  uppercase letter; a function starts with a lowercase letter or `_`. A violation is an error at
  the declaration.
- `#foreign` declarations keep their C names; they take C function pointers, never a trailing
  lambda.
- Values are not constrained. `MAX_ALIGN { ... }` names no type, so it is an error where written.
- Keywords and primitives are outside the rule: none is ever followed by a construction `{`.
- No declaration in the compiler, stdlib, tools or harness breaks the rule today.

Later, `.Upper {` can only be a type, which leaves room for module-qualified construction
(`ast.Point { x = 1 }`) and struct-payload variants without a collision.

### Removed

`fn(params) R { body }` as an expression. After migration it is an error whose hint gives the
brace form. `fn(T) R` as a type is unchanged.

## Before and after

```flang
// lib/flang_analysis/src/demand.f
row.sort_by(fn(i) { name_of(fqns, i) })
row.sort_by { name_of(fqns, it) }

// stdlib/core/slice.f
s.fold(0i32, fn(a: i32, b: i32) i32 { a + b })
s.fold(0i32) { a, b => a + b }

// stdlib/std/rpc/jsonrpc.f
self.send(fn(e: &Encoder) void {
    e.key("id")
    e.encode_int(id, 8)
})
self.send { e =>
    e.key("id")
    e.encode_int(id, 8)
}

// stdlib/std/io/internal/fs.f
return with_c_path(from, fn(f: &u8) Result((), FsError) {
    return with_c_path(to, fn(t: &u8) Result((), FsError) {
        let err: i32 = 0
        return check(__flang_fs_rename(f, t, &err), err)
    })
})
return with_c_path(from) { f =>
    with_c_path(to) { t =>
        let err: i32 = 0
        check(__flang_fs_rename(f, t, &err), err)
    }
}
```

## Implementation plan

Each step lands with harness tests. The old form stays accepted until step 6.

1. **Parser** (`flang_parser`). The brace lambda in argument position, in trailing position after
   a lowercase name or call, and in other expression positions by the two-token test. The
   projector produces the existing `LambdaExpr` with a flag for an arrow-less body.
2. **Checker** (`flang_typer`). Arrow-less arity from the expected callable, binding `it`.
   Trailing-lambda binding to the last callable parameter in call resolution. The case rule at
   declarations. New error codes in `docs/error-codes.md`: case rule (type, function), arrow-less
   lambda where more than one parameter is expected, trailing lambda with no callable parameter,
   a non-defaulted parameter after the one it fills.
3. **Formatter** (`flang_fmt`). Single-line `{ x => x }` when it fits; otherwise the parameters
   stay on the opening brace's line and the body is indented.
4. **Bounds** on the stdlib's remaining unbounded callback parameters.
5. **Promote**, then migrate the 100 compiler and stdlib lambdas and the 81 harness lambdas.
6. **Remove** the `fn(...) { }` expression; its error points at the brace form. Promote.
7. **Docs.** `spec.md` §7.3 and the naming rule, `syntax.md` (lambda line, FLang-vs-Rust table),
   `architecture.md` (parser disambiguation).

### Implementation status

- Implemented 2026-10-18: parser, projector, checker (`it` arity E2154, case rule E2155, trailing
  slot E2156), formatter, docs. One code covers both binding errors: a required parameter after
  the last callable one leaves no slot.
- A lambda argument is checked after its call resolves, against the parameter it fills: its
  parameters take the expected types first, and an expected `void` return discards the body's
  value (the migration needed it: `fn(e) void { ... e.end_map() }` became `{ e => ... }`).
- Step 4 needed no change outside two harness helpers: every stdlib callback already carried a
  `fn` bound.
- Migration: 188 lambdas rewritten from CST spans (trailing where the call allowed it), 20 more in
  compiler test sources. The `fn(...) { }` expression is E1053.

## Out of scope

- Generic lambdas' semantics (`{ x: $T => ... }` parses; what it instantiates is the next RFC).
- Returning from the enclosing function out of a lambda (Kotlin's non-local return). E1054 keeps
  `return` free for it.
- Destructuring parameters.
