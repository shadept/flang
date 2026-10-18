---
status: accepted
type: language
created: 2026-10-11
relates: [RFC-014, RFC-033, RFC-035, RFC-038, RFC-041]
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
xs.sort_by { it + off }                // a capturing closure, passed as `fn(T) K`
```

A `fn` value is two words, a code pointer and an environment pointer, and it borrows the callable
it was made from, as a slice borrows its elements. Every FLang function takes the environment as a
hidden last parameter, after the context, so any function is its own entry point and no adapter
is generated. The monomorphized form stays available as an
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
code: the entry point, a `flang` function taking (P1, ..., Pn, ctx, env)
env:  &u8?, the callable's state, or null
```

Calling it calls `code(args, ctx, env)`. Parameter modes stay part of the type: `fn(T)` and
`fn(move T)` remain distinct, and a callable converts only to a function type its own signature
fits, by RFC-035's subsumption rules (a reading parameter fits a `move` slot; a `move` parameter
fits only a `move` slot).

### Calling convention

Every `flang` function takes two hidden parameters after its own: the context (RFC-038), then
`env`. In C, where the pair crosses by address like every aggregate (spec 3.2; RFC-041 splits it
into two registers on a native backend):

```c
typedef struct {
    int32_t (*code)(int32_t x, const Context *ctx, void *env);
    void *env;
} Fn_i32_i32;

int32_t twice(int32_t x, const Context *ctx, void *env) { return x * 2; }

int32_t apply(int32_t x, const Fn_i32_i32 *f, const Context *ctx, void *env) {
    return f->code(x, ctx, f->env);
}

twice(21, ctx, NULL);                  // a direct call passes a null env
Fn_i32_i32 tmp = { twice, NULL };      // a named function needs no adapter
apply(21, &tmp, ctx, NULL);
```

- `env` is the state of the function being called, one per call, as `this` is for a C++ method.
  Each `fn` argument carries its own: `match(r, t, f)` calls `t.code(v, ctx, t.env)` and
  `f.code(e, ctx, f.env)`. A function's own `env` is read only by a closure body; every other
  function ignores it.
- Every function takes `env`, not only the ones converted somewhere, so a function's C signature
  does not depend on how other modules use it. Dropping it from functions never converted is a
  later optimization; the design works without it.
- The hidden parameters go last so the user's arguments keep the argument registers. Registers
  fill left to right, so when they run out the hidden ones spill first, `env` before `ctx`: a
  spilled `env` costs the caller one store of null, never read. `ctx`'s register varies with the
  callee's arity, a move per call in a function that already keeps it in a callee-saved register.
  A native backend pins `ctx` to a register (RFC-038), which makes its position moot.

### Linkage

Every generated function is `static`, so the C compiler sees every call site: it drops a hidden
parameter a function never reads, specializes a callee for a constant `code`, and deletes a body
it inlined everywhere. A non-`static` function keeps its full signature and an out-of-line body
whatever happens to its callers. External linkage remains for `main`, `#foreign` functions, the
generated entry points (test runner, constant initializers), and `pub` functions when the build
root is `kind = "lib"`. A library built as a dependency compiles into its executable's single
translation unit, and its `pub` functions are `static` there too.

### Conversion

A callable converts to a function type where a value of that type is expected: an argument, an
initializer, an assignment, a field.

| Callable | `code` | `env` |
|---|---|---|
| A named function, a non-capturing lambda | the function itself | null |
| A capturing closure | the closure's body, reading its captures through `env` | the closure's address |
| A value with `op_call(self: &Self, ...)` | a thunk passing `env` as `self` | the value's address |
| A `fn` value | unchanged | unchanged |

An overloaded name converts to the overload whose signature is the function type it fills. A thunk
is emitted once per `op_call` type that is converted.

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

The default is erasure. The monomorphized form gives a capturing closure or an `op_call` type its
own instantiation and a direct call; a named function or a non-capturing lambda has the type
`fn(T) R` itself, so it erases under either form, as it does today. It suits an inner loop where a
benchmark shows the inlined call matters, and a struct that must own a stateful `op_call` value
rather than borrow it.

### The standard library

- Callback parameters take function types: `filter(keep: fn(T) bool)`, `fold(f: fn(A, T) A)`,
  `sort(cmp: fn(T, T) Ord)`, `sort_by(key: fn(T) $K)`, `get_or_insert_with(make: fn() V)`.
- No stdlib function takes `$F where F: fn(...)` for now. The choice between the forms sits in
  the callee's signature, ahead of any caller, and a library cannot know which of its callers run
  a capturing closure in a hot loop. `sort(s) where T: Ordered` compares through a non-capturing
  lambda, which erases under either form.
- The `std.iter` adapters store their callback as a `fn` value, so `FilterIter(I: Iterator)` holds
  `f: fn(I.Item) bool` and takes no callable type parameter. Each chain instantiates per iterator
  type only.
- The vtable structs (`Allocator`, `Reader`, `Writer`, the codec interfaces) keep their source
  form. Each slot becomes a pair, and the explicit `&u8` receiver they pass today can move into
  `env` in a follow-up.

### Foreign code

C calls a single code pointer in its own convention. The thin form spells that convention the way
a declaration does, with `#foreign` in type position as `#foreign struct` already is:
`#foreign(conv) fn(P...) R` is one code pointer with no context and no `env`. A bare `#foreign`
is `#foreign(c)`, for types and declarations alike, and the argument names any other convention
in both places (`#foreign(stdcall) fn MessageBoxA(...)`).

```flang
#foreign fn malloc(size: usize) &u8?                        // = #foreign(c)
#foreign fn qsort(base: &u8, n: usize, size: usize, cmp: #foreign fn(&u8, &u8) i32)

type CCompare = #foreign fn(&u8, &u8) i32
type WndProc = #foreign(stdcall) fn(&u8, u32, usize, isize) isize

type Callbacks = #foreign struct {
    on_key: #foreign fn(&u8, i32, i32, i32, i32)
}
```

- **Conversion.** A `#foreign` function of that convention converts as itself. A named FLang
  function or a non-capturing lambda converts through a thunk in that convention that supplies the
  root context and a null `env` (RFC-038), emitted once per function and convention. A capturing
  closure does not convert: a single pointer has no slot for its environment (E2111).
- **Calls.** A call through a `#foreign(conv) fn` is a plain call in that convention.
- **`#foreign struct` fields.** A function-typed field names its convention; a plain `fn(...)`
  field, a two-word pair inside a C layout, is an error at the declaration.
- **The other direction.** A `#foreign` function is no `fn(...)` value, as today. A reverse thunk
  dropping the context and `env` would make one; not until something needs it.

### TypeInfo

`type_info(fn(T) R)` keeps `kind = TypeKind.Function`; its `size` and `align` become those of the
pair.

## Errors

- E2111 (a capturing closure to a bare function pointer) is withdrawn for `fn(...)`, and keeps its
  code for `#foreign(conv) fn(...)`.
- New, numbered when the step lands: a `#foreign struct` field of a plain `fn(...)` type.
- New, numbered when the checker step lands: a callable whose signature does not fit the function
  type it converts to, reported at the conversion with both signatures.

## Plan

Steps 1 to 4 landed on 2026-10-18, without the `op_call` and `#foreign` thunks (known-issues,
"Function Values: `op_call` Types and C Callbacks Do Not Convert").

1. **Linkage.** Generated functions `static`, with the exceptions above.
2. **Calling convention.** `ctx` moves from first to after the user's parameters, and `env` is
   added after it, on every `flang` function, closure body and test block (RFC-038's ABI).
3. **Lowering and the C backend.** The pair type, calls through it, and the `op_call` and
   `#foreign` thunks.
4. **Checker.** The conversions in the coercion ladder, the subsumption check at each, and the
   thin form for `#foreign` signatures.
5. **Harness**, then **promote**.
6. **Measure.** Sorting `i32` and `String`, and an iterator chain, erased against monomorphized,
   with the C compiler's specialization of a constant `code` in view. The numbers decide whether
   the opt-in stays, and whether a caller-side form is needed.
7. **Stdlib.** Callback parameters to function types; the `std.iter` adapters drop their callable
   type parameter.
8. **Docs.** Spec 2.2 and 3.2 (function types), 4.x ABI, 7.3 (callbacks); architecture's calling
   conventions; the error registry.

## Measurement (2026-10-18)

A recursive Lomuto quicksort over 4M `i32`, written twice with identical bodies, one taking
`cmp: fn(i32, i32) Ord` and one `cmp: $F where F: fn(i32, i32) Ord`; release build (`-O2`), Apple
clang 21, arm64, three runs:

| Comparator | Erased | Monomorphized |
|---|---|---|
| Named function `cmp_i32` | 299-335 ms | 303-320 ms |
| Capturing closure calling `cmp_i32` | 338-374 ms | 255-265 ms |

- A named function costs the same either way: it has the type `fn(i32, i32) Ord`, so the generic
  form instantiates for that type and calls through the pair too.
- A capturing closure costs about 35% more erased: the monomorphized body calls it directly and
  inlines `cmp_i32`, which is also why it beats the named function.
- Clang did not specialize the erased callee for its constant `code`, at `-O2` or `-O3`, with every
  function `static`: the generated assembly keeps the indirect `blr`. The recursion is the likely
  reason; a non-recursive callee was not tried.

## Alternatives considered

- **Generics everywhere (today).** One instantiation per callable type, and callbacks inline, but
  instantiations multiply with every closure and every signature restates its bound.
- **A function type in a parameter as shorthand for a bounded type parameter**, as RFC-035 does for
  contracts. The signature reads well, but every callback is still monomorphized.
- **One representation for both, always erased.** The simplest model, but it forfeits inlining
  where a sort or an iterator chain needs it, with no way back. Revisit after the measurement: a
  `static` callee called with a constant `code` may be specialized by the C compiler anyway.
- **`env` first, `code(env, args)`.** Shifts every user argument by one register, so a named
  function needs an adapter that drops `env`.
- **No `env` on plain functions, called with an extra trailing argument anyway.** Byte-identical to
  the chosen convention and harmless on SysV, AArch64 and Win64, but undefined in C: WebAssembly's
  `call_indirect` traps on the mismatch, CFI builds reject it, and the C optimizer may miscompile
  the call once it sees the target.
- **Hidden parameters first, `(ctx, env, args)`**, as C++ `this` and Clang Blocks. Fixed
  registers for both, but every direct call gives up two argument registers to state only closure
  bodies read: two left for the user on Win64.
- **A one-word value, Go's layout.** A pointer to `{code, captures...}`, the value itself passed as
  `env`; a named function becomes a static `{code}` record. Half the size, one extra load per
  call, and the closure struct must begin with its code.

## Open questions

- **Equality of `fn` values:** by `code` and `env`, or not comparable?
- **`op_call` values:** a thunk per converted type, or emit `op_call` with `self` in the `env`
  slot so it converts without one?
- **The vtable structs:** pairs, doubling each slot, or the thin form?
- **An external `pub fn` of a library** takes the hidden parameters: a C caller supplies a context,
  or the library exports C-convention thunks?
- **An owning callable** (a closure that outlives its frame, boxed with an allocator): out of scope
  here; RFC-033 notes closures that own their captures as future work.
- **A caller-side opt-in:** the callee's author picks erased or monomorphized, not the caller who
  knows the loop is hot. Whether the C compiler specializes a `static` callee for a constant `code`
  (plan step 6) decides whether a call-site form is ever needed.
