---
status: implemented
type: language
created: 2026-10-11
implemented: 2026-10-19
relates: [RFC-014, RFC-033, RFC-035, RFC-038, RFC-041]
---

# RFC-037: Function types as callable values

## Summary

A function type `fn(T) R` becomes the type of any function or closure of that shape: a named
function, a lambda, or a capturing closure. Each converts to it where it is passed, and the callee
is compiled once:

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
`fn(move T)` remain distinct. A reading parameter fits a `move` slot only when its type is
copyable: under erasure the callee cannot release what a `move` caller hands it, so a non-copyable
reader would leak. A `move` parameter fits only a `move` slot: a reading caller lends its own
storage. An unannotated lambda parameter takes the slot's mode.

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
| A `fn` value | unchanged | unchanged |

An overloaded name converts to the overload whose signature is the function type it fills. A value
with `op_call` does not convert: wrap it in a closure, `{ v(it) }`, or pass it through `$F`.

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
own instantiation and a direct call, and is the only form an `op_call` value fills; a named function or a non-capturing lambda has the type
`fn(T) R` itself, so it erases under either form, as it does today. It suits an inner loop where a
benchmark shows the inlined call matters, and a struct that must own a stateful `op_call` value
rather than borrow it.

### The standard library

- Callback parameters take function types: `filter(keep: fn(T) bool)`, `fold(f: fn(move A, T) A)`,
  `sort(cmp: fn(T, T) Ord)`, `sort_by(key: fn(T) $K)`, `get_or_insert_with(make: fn() V)`.
- No stdlib function takes `$F where F: fn(...)` for speed. The choice between the forms sits in
  the callee's signature, ahead of any caller, and a library cannot know which of its callers run
  a capturing closure in a hot loop. `sort(s) where T: Ordered` compares through a non-capturing
  lambda, which erases under either form.
- `Option`'s `map` and `flat_map` and `Result`'s `map`, `map_err` and `and_then` keep
  `$F where F: fn(move T) U` for ownership. They hand the payload over, and a non-copyable reader
  such as `opt.map(extract)` fits a `move` slot only through an adapter that releases the payload
  after the call. The instantiation sees the callback's own mode instead, until `move` parameters
  are released at scope end.
- The `std.iter` adapters store their callback as a `fn` value, so `FilterIter(I: Iterator)` holds
  `f: fn(I.Item) bool` and takes no callable type parameter. Each chain instantiates per iterator
  type only.
- The vtable structs (`Allocator`, `Reader`, `Writer`, the codec interfaces) keep their source
  form. Each slot becomes a pair, and the explicit `&u8` receiver they pass today can move into
  `env` in a follow-up.

### Foreign code

Every function has a calling convention. `flang` is the default: the context and `env` follow the
arguments. `#foreign` names another, on a declaration and on a function type alike, and a bare
`#foreign` is `#foreign(c)`. A `#foreign fn` type is one code pointer in that convention, with no
context and no `env`.

```flang
#foreign fn qsort(base: &u8, n: usize, size: usize, cmp: #foreign fn(&u8, &u8) i32)

// Defined in FLang, called by C.
#foreign fn by_score(a: &u8, b: &u8) i32 {
    return (b as &Player).score - (a as &Player).score
}

type Compare = #foreign fn(&u8, &u8) i32

type Callbacks = #foreign struct {
    on_key: #foreign fn(&u8, i32, i32, i32, i32)
}

qsort(base, n, size, by_score)
qsort(base, n, size, { a, b => (a as &Player).score - (b as &Player).score })
```

- **Bodies.** A `#foreign fn` with a body is a FLang function in that convention: C calls it by its
  C name, and it runs under the root context (RFC-038). FLang calls it directly, as it calls any
  `#foreign` function.
- **Conversion.** No thunk: a value already in the convention converts as itself. That is a
  `#foreign` function, with or without a body, and a non-capturing lambda written where a
  `#foreign fn` is expected, which is emitted in that convention. A capturing closure has nowhere
  to keep its environment, and a `flang` function or `fn` value takes the context C does not pass;
  neither converts (E2111).
- **Calls.** A call through a `#foreign fn` value is a plain call in its convention.
- **`#foreign struct` fields.** A function-typed field is a `#foreign fn`; a plain `fn(...)`
  field, a two-word pair inside a C layout, is an error at the declaration (E2157).
- **The other direction.** A `#foreign fn` is no `fn(...)` value. A closure calling it,
  `{ cmp(it, x) }`, is one.
- **Conventions.** `c` is the one implemented. `#foreign(stdcall)`, `#foreign(rust)` and the like
  are later conventions on the same mechanism, each a function type of its own, so other languages
  call FLang bodies declared in theirs.
- **Aggregates by value.** A `#foreign fn` body or call through a `#foreign fn` value with a struct
  parameter or return passed by value is refused in lowering (known-issues).

### TypeInfo

`type_info(fn(T) R)` keeps `kind = TypeKind.Function`; its `size` and `align` become those of the
pair.

## Errors

- E2111 (a capturing closure to a bare function pointer) is withdrawn for `fn(...)`, and keeps its
  code for `#foreign fn(...)`: a capturing closure, a `flang` function or a `fn` value passed as
  one.
- E2157: a `#foreign struct` field of a plain `fn(...)` type.
- New, numbered when the checker step lands: a callable whose signature does not fit the function
  type it converts to, reported at the conversion with both signatures.

## Plan

Steps 1 to 6 landed on 2026-10-18, with the `#foreign fn` type; steps 7 and 8 on 2026-10-19,
after the copyable `move`-slot rule and the seed promote they needed.

1. **Linkage.** Generated functions `static`, with the exceptions above.
2. **Calling convention.** `ctx` moves from first to after the user's parameters, and `env` is
   added after it, on every `flang` function, closure body and test block (RFC-038's ABI).
3. **Lowering and the C backend.** The pair type, calls through it, and `#foreign fn`.
4. **Checker.** The conversions in the coercion ladder, the subsumption check at each, and the
   `#foreign fn` type.
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
- **`op_call` values convert through a thunk** passing `env` as `self`, emitted once per converted
  type. Dropped: the closure `{ v(it) }` does the same at the call site with no thunk, and `$F`
  keeps the direct call.
- **A C-convention thunk per FLang function** passed as `#foreign fn`, supplying the root context
  and a null `env`. Dropped: a body declared `#foreign` is that function with no second symbol,
  and the same mechanism carries the later conventions.
- **A one-word value, Go's layout.** A pointer to `{code, captures...}`, the value itself passed as
  `env`; a named function becomes a static `{code}` record. Half the size, one extra load per
  call, and the closure struct must begin with its code.

## Open questions

- **Equality of `fn` values:** by `code` and `env`, or not comparable?
- **The vtable structs:** pairs, doubling each slot, or the thin form?
- **An external `pub fn` of a library** takes the hidden parameters. A function meant for C callers
  is declared `#foreign fn` with a body; whether a `kind = "lib"` build also exports its `flang`
  functions is open.
- **An owning callable** (a closure that outlives its frame, boxed with an allocator): out of scope
  here; RFC-033 notes closures that own their captures as future work.
- **A caller-side opt-in:** the callee's author picks erased or monomorphized, not the caller who
  knows the loop is hot. Whether the C compiler specializes a `static` callee for a constant `code`
  (plan step 6) decides whether a call-site form is ever needed.
