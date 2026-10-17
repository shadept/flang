---
status: implemented
type: language
created: 2026-10-17
implemented: 2026-10-18
relates: [RFC-005, RFC-014, RFC-037]
---

# RFC-038: Runtime context

## Summary

Every FLang function runs under one current `Context`: a struct the compiler assembles from
`context` field declarations across the whole program, passed to every FLang function as a hidden
first parameter. Code reads it, copies it and rebinds it for a scope; it never mutates it.

```flang
// std/allocator.f
pub context allocator: &Allocator = &global_allocator

// std/log.f
pub context logger: &Logger = &stderr_logger
context span_depth: u32 = 0             // module-private

fn handle(req: &Request) {
    context.logger.info("start")
    let saved = context                 // a copy, type `Context`
}
```

It replaces `set_global_allocator`, gives scoped allocators (frame, request), logging, test
isolation and, later, structured concurrency one mechanism, and moves RFC-005 §3.5's library
`Context` into the language.

## Motivation

- **Explicit allocators everywhere.** 178 stdlib signatures take `allocator: &Allocator`, the
  managed/unmanaged container split exists to thread it, and a callback-taking function competes
  with it for the last parameter.
- **`set_global_allocator` is a mutable global.** `std/test.f` and `std/sort.f` swap it by hand;
  it is neither scoped nor per-task.
- **Scoped state has no home.** A frame allocator, a request allocator, a logger with request
  fields, a test's panic handler, a deadline: each needs dynamic scope.

## Design

### Declaration

```
[pub] context <name>: <Type> = <initializer>
```

- Top-level only. The type annotation and the default are required; there is no zero-init.
- The default is a constant initializer (literal, address of a global), so the root context is a
  static and exists before constant initialization runs.
- The field type is `copyable`: the language copies a context (on `let c = context`, a capture, a
  `defer`, a rebind, a detached spawn), and an owned field would gain a second owner. Shared or
  owned state goes in by reference (`&T`), owned by the scope that rebinds.
- Visibility is `pub` or module-private, as for any declaration; it covers read and rebind.

### Use

- `context.<name>` reads a field. A field resolves among the context fields visible from the
  module; two visible fields of one name are an ambiguity error.
- `context` alone is a value of type `Context`: a copy of the current context. `ctx.<name>` reads
  a saved copy the same way.
- The current context is never mutated in place and its address is never taken (`&context` is an
  error). Only copies escape.

### Rebinding

`context(args) { body }` runs `body` under a new context. It is a block construct like `for`,
`loop` and `match`, not a call: `return`, `?`, `break` and `defer` in the body act as in any
block. The change lasts exactly as long as the body; there is no form without one.

```flang
context(allocator = &req.arena) { handle(req) }
context(saved) { run(job) }
context(saved, logger = &req.log) { run(job) }

const mesh = context(allocator = &frame) {
    build_mesh(data)
}
```

- The arguments follow the call rule, as in `$(cap, allocator = &a)"..."`: an optional positional
  `Context` is the base (the current context when omitted), then named fields override it.
- A named field must be a context field visible to the module, at most once per rebind; its
  declaration types the value.
- The construct is an expression; its value is the body's.
- One token after `context` decides the form: `(` a rebind, `.` a field read, anything else a copy.

### Semantics

1. **Dynamic scope.** A callee runs under its caller's context at the time of the call.
2. **Closures do not capture the context.** A closure runs under whoever calls it. To run under
   the creator's context, capture a copy and rebind to it inside the body.
3. **`defer` captures its own context**: the deferred body runs under the context current where
   it was written.
4. **`spawn` captures** (RFC-005): a structured child keeps the parent's context, which outlives
   it; a detached task copies it.
5. **Generics are unaffected.** The context is not part of an instantiation key.

### ABI

- **Two conventions.** `flang`: every FLang function, closure `op_call`, test body and
  `#inline` body; takes `const Context *` as its first C parameter. `c`: `#foreign` functions; no
  context.
- **`fn` values carry `flang`.** An indirect call passes the context first; under RFC-037 the code
  pointer is `R code(ctx, env, args...)`.
- **Entry.** C `main` initializes the runtime and passes the address of the static root context
  to the constant initializers, to FLang `main`, and to each test function.
- **Rebinding** builds a new `Context` in the current frame (copy of the base with the named
  fields replaced) and passes its address within the body. Exit needs no code: the outer
  pointer is still live in the frame, so `return`, `?` and panics are correct.
- **Register.** On the C backend the context arrives in the first argument register; the C
  compiler places it from there. Pinning a register is a native-backend decision, deferred until
  that backend exists.
- Not crossing C: a C-to-FLang callback has no context. None exist today; when they do, they get
  the root context through a thunk.

### Assembly

1. **Registration.** Symbol registration records each `context` declaration as a symbol of its
   module (name, type, default), alongside globals. No new pass.
2. **Checking.** `context.f` types from `f`'s declaration alone; no module's check depends on the
   assembled struct, so the LSP has no cross-module invalidation from it.
3. **Layout**, once, in `build_program`: every registered field, ordered by module FQN then
   declaration order (deterministic, as the stage-2 = stage-3 C check requires). The struct holds
   only fields from the import closure.
4. **Root.** One data-segment global with the defaults, through the existing constant-global and
   relocation path.

Cost: one symbol per field and one struct per program. Runtime cost: one argument per FLang call,
and a struct copy of the context size per rebind.

## Implementation plan

Each step lands with harness tests. Steps 1-5 use only seed-supported features; the stdlib uses
`context` only after the promote in step 6.

1. **Parser** (`flang_parser`). `context` keyword. `ContextDecl` at top level; `context` as a
   primary expression; the `context(args) { body }` construct. Formatter support
   (`flang_fmt`).
2. **Checker** (`flang_typer`). Register `ContextDecl`s with module visibility. Type `context` as
   the compiler-provided `Context`; resolve `.f` on a `Context` value among visible fields
   (ambiguity error); check a rebind's values against the fields' types. New errors, registered in
   `docs/error-codes.md`: field type not copyable, default not a constant initializer, `&context`,
   unknown context field, a field named twice in one rebind.
3. **FIR** (`flang_codegen/fir.f`). `CallConv` gains `Flang`. A `Flang` function's first
   `BlockParam` is the context; `CallIndirectInstr.cc` tells an indirect call whether to pass it.
   The C backend needs no special case beyond the root and `main`.
4. **Lowering** (`flang_driver/lower.f`, `compile.f`). Add the context param to every FLang
   function and forward it at every FLang call; `context.f` is a load at the field's offset;
   `context` is a struct copy; a rebind builds a new `Context` in the frame and makes its address
   the operand for the body; `defer` bodies use the context operand of their registration site.
   `build_program` lays out `Context` and emits the root global.
5. **C entry** (`c_backend.f`). Pass `&root` to the constant initializers, `main` and each
   `__flang_test_fns[i]`.
6. **Measure, then promote.** Self-build time and the compiler's own runtime before and after the
   extra parameter; `dotnet run promote.cs`.
7. **Allocator over the context** (stdlib). `pub context allocator`; `or_global(a)` resolves null
   to `context.allocator`; `set_global_allocator` is removed and `std/test.f` / `std/sort.f`
   rebind instead; each test runs under a context with the test allocator. No signature changes.
8. **Docs.** `spec.md` (new context section; §5 allocator rules), `syntax.md`, `architecture.md`
   (calling conventions, assembly), `CONTEXT.md` glossary, RFC-005 §3.5 marked superseded.

The calling-convention split is part of this RFC, not a separate ADR. The RFC is implemented
when steps 1-8 land; the follow-ups below do not block it.

### Implementation status

Steps 1-5 and 8 landed 2026-10-17, with these refinements over the plan above:

- **Layout is assembled by the checker**, at the end of `check_all` (`assemble_context`), as the
  fields of `core.runtime.Context`'s definition, with their FQNs in
  `TypeCheckResult.context_fields`. Ordinary layout queries then size the context; lowering
  reads offsets by FQN index. Checking still never reads the assembled fields.
- **`main` takes no context parameter**: the C entry point calls it, and it runs under the root
  global directly, as the constant initializers do. Test blocks take the parameter; the runner
  passes the root.
- **A `#foreign` function used as a `fn` value is refused** at lowering rather than wrapped in a
  thunk.
- **Errors**: E2147 not copyable, E2148 default not constant, E2149 the current context as a
  place (`&context`, `&context.f`, assignment), E2150 unknown field, E2151 a field named twice,
  E2152 ambiguous field, E2153 a misplaced base or a `Context` struct literal. A duplicate
  declaration is E2005, as for module constants.

Measured (step 6, win-x64, the same sources built once by the old-ABI seed and once by the new
compiler): the compiler's own runtime emitting its C is +1.6% (median of four, 1941 to 1972 ms);
the full release self-build is unchanged at 11.3 s, where the C compile dominates.

Step 6's promote is `seed/20261017`. Step 7 landed revised, 2026-10-18:

- `std.allocator` declares two fields, both defaulting to the global allocator: `allocator`, the
  default for everything, and `temp_allocator`, for memory nothing frees on its own, reclaimed all
  at once by the scope that rebinds it (a request, a frame, a test).
- `or_global`, `global()`, `set_global_allocator` and its slot are gone. An allocator parameter is
  `allocator: &Allocator = context.allocator`, so the stdlib signatures did change, from
  `&Allocator? = null`; a method defaulting to its receiver's allocator keeps the optional form.
  A null `&Allocator` (zero-initialization only) resolves to the current context's allocator per
  call.
- A context field registers before any signature, so a default value may read one.
- Each test runs through `std.test.run_test` under the tracking allocator and a temp arena reset
  before each test; the compiler's `--stats` ledger is a rebind in `main`.
- Until the next promote, `std.string_builder` keeps a `(usize, &Allocator?)` overload: the
  seed's `$"..."` desugar passes `null` for an omitted allocator.

### Follow-ups, separate RFCs

- **Collections over the context allocator.** Constructors capture `context.allocator`; the
  container field stays `&Allocator`; zero-init stops being a valid empty container (spec §5 rule
  2); the managed/unmanaged split and the defaulted allocator parameters go. The large stdlib
  change; it gets its own design.
- **Lambda syntax** (Kotlin-style braces, trailing lambda filling the callable-bounded parameter,
  `it`).

## Out of scope

- Register pinning (native backend).
- Context for C-to-FLang callbacks (TLS slot), until a callback exists.
- Bare `logger` resolving to a context field when ordinary lookup fails. Revisit if `context.`
  proves too heavy in server code.
- Dropping fields nothing reads; pruning the parameter from functions that never need it.
- Parallel children sharing a non-thread-safe allocator (RFC-005).
- `with`: reserved for a different feature (Visual Basic style member blocks), not for context.
