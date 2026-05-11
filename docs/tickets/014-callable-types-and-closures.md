# RFC-014: `op_call` and closure literals

**Type:** Language feature
**Status:** Phase 1 landed (op_call). Phase 2 (capturing lambdas) landed for the by-value case; nested-capture closures (E2113) and stdlib follow-ups (generic iterator types, `box(allocator, callable)`) tracked separately in [known-issues.md](../known-issues.md#rfc-014-phase-2-follow-ups).
**Depends on:** RFC-007 (Option as enum) — only as background; not load-bearing

## Summary

Two closely-related additions, sequenced:

1. **`op_call`** (priority, ships first) — a user-definable operator that makes any type with the right method callable via `t(args)`. Joins the existing operator-via-named-function family (`op_deref`, `op_eq`, `op_index_ref`, …). Gives types the ability to act as functions.

2. **Capturing lambdas** — FLang's existing `fn(args) Ret { body }` lambda syntax (currently restricted to non-capturing forms by `_ctx.LambdaScopeBarrier`) is extended to support captures. The compiler synthesizes an anonymous struct holding the captures and an `op_call` method holding the body. Closures stop being a separate language feature and become "the literal form of a callable type." **No new lambda syntax is added** — the same `fn(args) Ret { body }` form covers both the value-position (anonymous, capturing) and declaration-position (named, top-level) uses.

Sequencing matters: (1) is a small, isolated language addition that stands on its own (Counter, Comparator-with-state, function objects). Once it's in, (2) reuses the existing lambda grammar — capture analysis is added; the syntactic surface doesn't change.

## Motivation

### `op_call` standalone

Several patterns currently require boilerplate or are inexpressible:

- **Stateful comparators / predicates / mappers** — `qsort` with a context, filter with thresholds, map with config. Today the user threads state through extra parameters or globals.
- **Function objects** — types that semantically *are* a function but carry state. Today they get a manually-named method (`.invoke()`, `.run()`) and read awkwardly at call sites.
- **Iterators-as-functions** — `next()` is a call; some streaming APIs would read more naturally as `iter()` returning the next value.

`op_call` joins the existing pattern that powers `op_deref`, `op_eq`, `op_index`, etc. — operator semantics implemented as named functions that the compiler dispatches to syntactically. No runtime change; the call site is rewritten to a regular function call.

### Closures (the consequence)

Once `op_call` exists, the only thing standing between FLang and capturing closures is parsing + capture analysis. The runtime model — anonymous struct holding captures, `op_call` holding the body — falls out of (1) for free.

Capturing lambdas unblock:

- **Allocator-aware cleanup** for `Owned` and similar wrappers without bundling allocator into every type that holds heap. `let s = owned(sv, |x| alloc.return_string(x))` instead of inventing a new `OwnedString`-shaped type per allocator/buffer pair.
- **Iterator chains with local state**: `arr.filter(|x| x > threshold).map(|x| x * scale)` where `threshold` and `scale` are locals, not globals or extra arguments.
- **Builders, DSLs, callback-style APIs** — patterns C libraries already implement by hand via `(callback, void* userdata)` pairs.

Today FLang has *non-capturing* lambdas (`fn(x: i32) i32 { x + 1 }`). The lambda scope barrier (`_ctx.LambdaScopeBarrier` in HmTypeChecker) explicitly prohibits captures. This RFC removes that barrier and replaces it with a capture-detection pass.

## Design

### Phase 1: `op_call`

Any type may declare a function named `op_call` whose first parameter is the receiver (by reference or by value). The compiler rewrites `t(args...)` to `op_call(&t, args...)` (or `op_call(t, args...)` for by-value receivers).

```
type Counter = struct { n: i32 }

fn op_call(self: &Counter) i32 {
    self.n = self.n + 1
    return self.n
}

let c = Counter { n = 0 }
c()    // → 1, desugars to op_call(&c)
c()    // → 2
c()    // → 3
```

Multiple `op_call` overloads on the same type are allowed (e.g. one taking `i32`, one taking `String`) and resolved by the existing overload mechanism.

**Interaction with `op_deref`**: when a type `T` has no matching `op_call` for the given args but has `op_deref(self: &T) &U` and `U` has a matching `op_call`, the existing op_deref chain extends one step into the call-resolution path. This makes `Owned(F)` callable when `F` is callable, without any special-casing for closures or wrappers.

### Phase 2: capturing lambdas

**No syntax changes.** FLang already has `fn(args) Ret { body }` lambdas — this RFC removes the non-capturing restriction. The same form covers anonymous functions whether or not they reference outer scope:

```
fn(x) { x * 2 }                          // no captures, plain function pointer
fn(x: i32) i32 { x * 2 }                 // typed, no captures
fn(x) { x * k }                          // captures k from enclosing scope
fn(v, acc) { v + acc }                   // multi-arg
fn() { compute() }                       // zero-arg
```

The grammar is the same as named-function declarations, minus the name:

```
NamedFunction := 'fn' Ident ParamList ReturnTypeOpt Block
LambdaExpr    := 'fn'       ParamList ReturnTypeOpt Block
```

This mirrors the rest of the language's "declaration form ↔ value form" symmetry: a `type` alias declares a struct/enum, while `.{ ... }` is the value form of an anonymous struct; `fn name(...)` declares a function, while `fn(...)` is the value form of an anonymous one. The keyword stays; the name becomes optional.

The lambda literal evaluates to a value of an anonymous struct type, generated by the compiler. Capture analysis identifies free variables in the body (variables referenced but not declared inside the lambda or as parameters), and the synthesized struct holds them as fields.

For `let k = 7; let f = fn(x) { x * k }`, the compiler emits roughly:

```
type __Closure_42 = struct { k: i32 }

fn op_call(self: &__Closure_42, x: i32) i32 {
    return x * self.k
}

// At the literal site:
let f = __Closure_42 { k = k }
```

`f(3)` then desugars to `op_call(&f, 3)` — the same path any other `op_call` user goes through.

**Capture mode** (initial scope of this RFC): captures are by *value*. The closure struct's fields hold copies of the captured values at construction time. This avoids lifetime issues and matches FLang's existing value-semantics conventions.

Future work — see "Out of scope" — covers explicit capture-by-reference (`&local`) and capture-by-move semantics. Initial design ships without these to keep the surface area small.

**Type of a closure**: each closure literal has its own anonymous type, similar to how each tuple `(i32, bool)` has its own anonymous struct type. Two closures with identical captures and bodies are *not* the same type. This is the right default for monomorphization (each closure body specializes the receiver) and aligns with how anonymous tuples already work.

**Storing closures in concrete types**: when a closure literal flows into a context whose target type is a *concrete* function-pointer type `fn(args) ret`, the compiler emits a coercion. Two cases:

| Captures | Coercion |
|---|---|
| None | Closure decays to a plain function pointer — same wire format as today's non-capturing lambdas. |
| Non-empty | Compile error (`E2XXX`): "closure captures variables; cannot coerce to bare function pointer. Wrap with `box(allocator, ...)` or store via a generic-typed slot." |

This keeps the language honest: capturing closures cannot silently appear in places that have no env storage. Users either pick generic storage (the closure's anonymous type travels by value) or explicit boxing via `Owned`.

### Examples

**With `Owned` (the motivating case from RFC-012)**:

```
let alloc = my_allocator
let buf = alloc.alloc_buf(1024)
let owned_buf = owned(buf, fn(b) { alloc.dealloc_buf(b) })
defer owned_buf.deinit()
// `alloc` is captured by value (the &Allocator pointer).
```

**Iterator chain**:

```
let threshold = 10
let scale = 2
let it = arr.iter().filter(fn(x) { x > threshold }).map(fn(x) { x * scale })
for v in it { println(v) }
```

`FilterIter` and `MapIter` become generic in their callable parameter (`F`):

```
type FilterIter = struct(I, T, F) { it: I, f: F }
pub fn filter(it: $I, f: $F) FilterIter(I, T, F) { ... }
```

Each closure shape produces its own monomorphization. See the inliner discussion in RFC-015 for how this stays cheap.

**`op_call` standalone (no closures)**:

```
type ColumnComparator = struct { col: usize, descending: bool }

fn op_call(self: &ColumnComparator, a: Row, b: Row) Ord {
    let result = op_cmp(a.cols[self.col], b.cols[self.col])
    return if self.descending { result.reverse() } else { result }
}

let cmp = ColumnComparator { col = 2, descending = true }
rows.sort(cmp)   // sort takes a callable; cmp dispatches via op_call
```

## Lowering

Lambda literal `fn(x) { body_using(captured) }`:

```c
// Emitted at the literal's enclosing module level:
struct __Closure_42 {
    /* fields for each capture */
    int captured;
};

static int __Closure_42_op_call(struct __Closure_42 *self, int x) {
    /* body, with `captured` rewritten to `self->captured` */
}

// At the call site:
struct __Closure_42 cl_tmp = { .captured = captured };
// User's code that received `cl_tmp` as a value uses it like any struct.
// `cl_tmp(arg)` lowers to `__Closure_42_op_call(&cl_tmp, arg)`.
```

For non-capturing lambdas the env struct is empty (size 0) and the C compiler typically eliminates references to it during optimization.

For capturing lambdas stored via `box(allocator, fn(...) { ... })`, `Owned`'s existing storage handles the heap-side lifecycle. The closure value is copied into allocator-allocated storage, the cleanup callback closes over the allocator (recursive use of the feature) — see `box` design in the implementation phase.

## Implementation phases

1. **`op_call` operator** (no closures yet)
   - Lexer/parser: no new syntax — `t(args)` already parses as a call expression.
   - HmTypeChecker: when resolving `t(args)` and `t`'s type has no matching call interpretation as a function reference, look up `op_call(self: T, args...) Ret` (or `&T`) on the type. Same pattern as `op_eq`, `op_deref`, etc.
   - Lowering: rewrite the call to a function call to the resolved `op_call` target.
   - Op_deref chain: extend the existing `OpDerefChain` mechanism to call expressions, so `Owned(Counter)::op_call` resolves through `Owned`'s op_deref.
   - **Tests**: harness tests for the `Counter` example, multi-overload `op_call` resolution, op_call through op_deref, op_call composing with UFCS.

2. **Capture-detection pass on existing `fn(...)` lambdas**
   - No parser changes — `fn(args) Ret { body }` already parses as `LambdaExpressionNode`.
   - Extend `LambdaExpressionNode` with a captured-variable list, populated by the capture pass.
   - HmTypeChecker pass: walk the body, identify free variables (referenced but not declared inside or as parameters), record their types and identities. Capture mode: by-value (initial scope).
   - Synthesis: at AST-lowering time, a lambda with non-empty captures emits an anonymous struct type and an `op_call` function; the literal becomes a struct literal of the anonymous type. Lambdas with empty captures continue to lower to plain function pointers (current behavior).
   - **Remove** `_ctx.LambdaScopeBarrier` — replaced by the capture pass. Existing non-capturing `fn(...)` lambdas continue to behave as before (their capture set is simply empty).

3. **Coercion to bare `fn(...) ret`**
   - When a closure literal flows into a `fn(...) ret` slot, check the capture set.
   - Empty → emit a plain function pointer.
   - Non-empty → diagnostic E2XXX with the suggested fix.

4. **Stdlib follow-ups (separate, not part of this RFC)**
   - Audit iterator types (`FilterIter`, `MapIter`, etc.) and make them generic over the callable type, so capturing closures work without boxing.
   - Add `box(allocator, callable)` to `std.owned`.

## Out of scope

- **Capture-by-reference (`&local`)**: requires either lifetime tracking or documented escape conventions. Tracked separately. Initial implementation captures by value only.
- **Capture-by-move semantics**: requires move semantics in the language, which FLang doesn't yet have. Defer.
- **Type erasure for heterogeneous closure storage** (`fn(T) U` as a fat-pointer carrying env): the bare-function-pointer coercion in §Phase 2 handles the trivial (no-capture) case. Erasure of capturing closures is a follow-up.
- **First-class closure trait hierarchy** (Rust's `Fn`/`FnMut`/`FnOnce`): FLang doesn't have traits. Pattern emerges naturally from `op_call` overload resolution and the by-value/by-ref receiver choice in the `op_call` declaration.
- **Inliner/DCE optimization** to keep monomorphization cheap: tracked in RFC-015. Not blocking; FLang already does eager monomorphization, and the C backend's optimizer handles small functions well in the meantime.

## Open questions

1. ~~**Closure syntax.**~~ **Resolved**: lambdas continue to use the existing `fn(args) Ret { body }` syntax — the same form that declares named functions, with the name elided. No new grammar; no `|x|` / `=>` / `\x` introduction. This preserves the language's "declaration form ↔ value form" symmetry (`type ... = ...` ↔ `.{ ... }`, `fn name(...) ...` ↔ `fn(...) ...`) and avoids visual collisions with match-arm tuple patterns or with the bitwise-or / or-pattern uses of `|`.
2. **Capture mode default.** By-value (initial scope of this RFC) vs by-reference. By-value is safer; by-reference matches what users typically expect when they write `fn(x) { use(local) }` and use `local` repeatedly. **Recommendation**: by-value default, with an explicit `&local` capture syntax to be designed in a follow-up.
3. **Should `op_call` allow value-receiver overloads?** `fn op_call(self: T, ...)` consumes the callable. Useful for one-shot closures (FnOnce-equivalent). **Recommendation**: yes — same as how other operators support both `&self` and `self` receivers.
4. **Disambiguation when a type has both an `op_call` and `op_deref` to a callable.** Pick `op_call` first (the type's own behavior beats deref-through). Existing operator dispatch has the same precedence rule for `op_eq` etc.
5. **Generic type inference for lambda parameters.** `arr.map(fn(x) { x * 2 })` — the lambda's `x` parameter has no annotation. Today's lambda inference (`lambda_generic_infer` test) handles this for non-capturing lambdas. Verify the same path covers capturing lambdas cleanly.

## Migration

- `op_call` is purely additive — no existing code is affected.
- Capturing lambdas are an extension of the existing `fn(args) Ret { body }` syntax. Lambdas that don't reference outer scope continue to type-check and lower exactly as today (empty capture set, plain function pointer). Lambdas that *do* reference outer scope previously errored out at the lambda scope barrier; after this RFC they type-check successfully and lower as captured closures via `op_call`.
- The behaviour change is: code that today produces an error like `cannot reference outer variable inside lambda` will now compile. No code that compiles today changes meaning.

## Tests

`op_call` (Phase 1):
- `tests/FLang.Tests/Harness/op_call/op_call_basic.f` — Counter example, observable state.
- `op_call_overloads.f` — multiple `op_call` overloads on the same type.
- `op_call_through_deref.f` — `Owned(Counter)` dispatches `c()` through op_deref.
- `op_call_value_receiver.f` — `op_call(self: T, ...)`.
- `error_op_call_no_match.f` — diagnostic when no `op_call` overload matches.

Capturing lambdas (Phase 2):
- `closures/closure_no_capture.f` — `fn(x) { x * 2 }` (sanity: existing non-capturing form still works after the barrier is removed).
- `closure_capture_value.f` — captures a local int by value.
- `closure_capture_struct.f` — captures a struct by value.
- `closure_in_iter_chain.f` — `arr.filter(fn(x) { x > t }).map(fn(x) { x * s })`.
- `closure_with_owned.f` — `owned(buf, fn(b) { alloc.free(b) })`.
- `error_closure_to_bare_fnptr.f` — non-empty captures coerced to `fn(...) Ret` rejected.
- Stdlib embedded tests in `std/owned.f` covering the `box` integration.

## Out-of-scope notes (for the file)

- This RFC does **not** specify the inliner/DCE work. See RFC-015 for the optimization-side story. `op_call` and closures are correct without it; performance is "good enough" via the C backend's existing optimizer for the initial release.
- This RFC does **not** specify type erasure of capturing closures. The compile-error path on bare-fnptr coercion is the v1 contract. Erasure is tracked as a follow-up.
