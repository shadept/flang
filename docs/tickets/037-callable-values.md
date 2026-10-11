---
status: draft
type: language
created: 2026-10-11
relates: [RFC-014, RFC-033, RFC-035]
---

# RFC-037: Function types as callable values

## Summary

A function type `fn(T) R` becomes the type of any callable of that shape: a named function, a
lambda, a capturing closure, or a value with a matching `op_call`. Each converts to it where it is
passed, and the callee is compiled once:

```flang
pub fn sort(s: $T[], cmp: fn(T, T) Ord)
pub fn sort_by(s: $T[], key: fn(T) $K) where K: Ordered

let off = 100
xs.sort_by(fn(x) { x + off })          // a capturing closure, passed as `fn(T) K`
```

A `fn` value is two words, a code pointer and an environment pointer, and it borrows the callable
it was made from, as a slice borrows its elements. The monomorphized form stays available as an
opt-in: `$F where F: fn(T) R` instantiates the callee per callable type, for an inner loop that
gains from inlining the call.

## Motivation

- **Every distinct closure re-instantiates its callee.** A closure has an anonymous type of its
  own, so `xs.sort_by(f)` and `xs.sort_by(g)` instantiate `sort_by`, `sort`, `powersort` and its
  helpers twice. The cost grows with every call site, and most of these calls are not hot.
- **The signature says less than it should.** `cmp: $F where F: fn(T, T) Ord` introduces a type
  parameter only to bound it. `cmp: fn(T, T) Ord` states the parameter's meaning directly.
- **Today `fn(T) R` refuses closures.** It is a bare code pointer with no room for an environment,
  so a capturing closure passed to it is E2111. Every higher-order function is pushed to the
  generic form to accept one.
- **Erased signatures read the same everywhere.** A body that takes `cmp: fn(T, T) Ord` types
  `cmp` as that, in diagnostics and in the editor, independent of any instantiation.

## Design

### Representation

A value of type `fn(P1, ..., Pn) R` is a pair:

```
code: fn(env: &u8?, P1, ..., Pn) R      // the entry point, taking the environment first
env:  &u8?                               // the callable's state, or null
```

Calling it calls `code(env, args)`. Parameter modes stay part of the type: `fn(T)` and
`fn(move T)` remain distinct, and a callable converts only to a function type its own signature
fits, by RFC-035's subsumption rules (a reading parameter fits a `move` slot; a `move` parameter
fits only a `move` slot).

### Conversion

A callable converts to a function type where a value of that type is expected: an argument, an
initializer, an assignment, a field.

| Callable | `code` | `env` |
|---|---|---|
| A named function, a non-capturing lambda | an adapter that drops `env` and calls it | null |
| A capturing closure | the closure's `op_call`, taking its environment as `env` | the closure's address |
| A value with `op_call(self: &Self, ...)` | that `op_call` | the value's address |
| A `fn` value | unchanged | unchanged |

An adapter is emitted once per function that is converted, beside the function itself.

### Borrowing

A `fn` value is a view: it holds the address of the callable it came from and owns nothing, so it
is copyable and needs no release. It is valid while that callable is. A closure is already bound
to its frame (RFC-033: it captures by reference), so the rule adds no new restriction for
closures: a `fn` value made from a closure lives no longer than the frame that made the closure.
A `fn` value made from a named function or a non-capturing lambda has a null environment and is
valid anywhere.

### Erasure by default, monomorphization by opt-in

The two forms coexist, and the declaration chooses the dispatch strategy:

| Form | Compiled | A call |
|---|---|---|
| `f: fn(T) R` | once | indirect, through the pair |
| `f: $F where F: fn(T) R` | per callable type | direct, inlinable |

The default is erasure. The monomorphized form is for an inner loop where a benchmark shows the
inlined call matters, such as sorting primitives by `op_cmp`.

### The standard library

- Callback parameters take function types: `filter(keep: fn(T) bool)`, `fold(f: fn(A, T) A)`,
  `sort(cmp: fn(T, T) Ord)`, `sort_by(key: fn(T) $K)`, `get_or_insert_with(make: fn() V)`.
- `sort(s) where T: Ordered` keeps a monomorphized internal path, since it compares by `op_cmp`
  with no closure type to multiply instantiations.
- The `std.iter` adapters store their callback as a `fn` value, so `FilterIter(I: Iterator)` holds
  `f: fn(I.Item) bool` and takes no callable type parameter. Each chain instantiates per iterator
  type only.
- The vtable structs (`Allocator`, `Reader`, `Writer`, the codec interfaces) keep their source
  form. Each slot becomes a pair, and the explicit `&u8` receiver they pass today can move into
  `env` in a follow-up.

### Foreign code

C calls a single code pointer. A `#foreign` signature that takes or returns a function type uses
the thin form: a named function or a non-capturing lambda converts to it by its own symbol, and a
value with an environment does not convert (an error at the conversion).

### TypeInfo

`type_info(fn(T) R)` keeps `kind = TypeKind.Function`; its `size` and `align` become those of the
pair.

## Errors

- E2111 (a capturing closure to a bare function pointer) is withdrawn for non-foreign function
  types, and keeps its code for a `#foreign` signature.
- New, numbered when the checker step lands: a callable whose signature does not fit the function
  type it converts to, reported at the conversion with both signatures.

## Plan

1. **Lowering and the C backend.** The pair type, calls through it, and the per-function adapters.
2. **Checker.** The conversions in the coercion ladder, the subsumption check at each, and the
   thin form for `#foreign` signatures.
3. **Harness**, then **promote**.
4. **Measure.** Sorting `i32` and `String`, and an iterator chain, erased against monomorphized.
   The numbers decide which stdlib paths keep the monomorphized form.
5. **Stdlib.** Callback parameters to function types; the `std.iter` adapters drop their callable
   type parameter.
6. **Docs.** Spec 2.2 and 3.2 (function types), 7.3 (callbacks); the error registry.

## Alternatives considered

- **Generics everywhere (today).** One instantiation per callable type, and callbacks inline, but
  instantiations multiply with every closure and every signature restates its bound.
- **A function type in a parameter as shorthand for a bounded type parameter**, as RFC-035 does for
  contracts. The signature reads well, but every callback is still monomorphized.
- **One representation for both, always erased.** The simplest model, but it forfeits inlining
  where a sort or an iterator chain needs it, with no way back.

## Open questions

- **Spelling of the thin form** outside `#foreign` signatures: none, or `extern fn(...)` for a C
  callback stored in a field?
- **Equality of `fn` values:** by `code` and `env`, or not comparable?
- **An owning callable** (a closure that outlives its frame, boxed with an allocator): out of scope
  here; RFC-033 notes closures that own their captures as future work.
