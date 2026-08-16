# ADR 0004 — Symbol assignment belongs to lowering (self-hosted compiler)

**Status:** Accepted — binds the self-hosted compiler; the C# reference is permanently exempt
**Date:** 2026-08-16
**Affects:** `docs/spec.md` §7.1.1; `lib/flang_driver/src/lower.f`; `lib/flang_codegen/src/c_backend.f`

## Context

FLang allows overloading, generic specialization, and same-named functions in
different modules. C does not. Something must give each function a unique link
symbol. That "something" was never specified, and the two compilers landed in
different layers.

**Self-hosted**: lowering assigns symbols; `c_backend.f` emits `c.callee`
verbatim — one line, no knowledge of overloading.

**C# reference**: the IR carries unmangled names (`IrFunction.Name`,
`CallInstruction.FunctionName`) and `HmCCodeGenerator` re-derives the symbol at
emit time — separately at the definition (`MangleFunctionName(IrFunction)`) and
again at every call site. A third identity scheme (`SemanticKey`,
`name|params|ret`) exists alongside, invented so `InliningPass` could match
callers to callees because the IR carried no authoritative identity.

The C# arrangement is fragile: the definition mangles from `fn.Params` (skipping
the sret parameter when `UsesReturnSlot`), while the call site mangles from
`call.CalleeIrParamTypes` — assigned only `if (calleeParamTypes != null)`
(`BasicBlock.cs:171,185`) and otherwise falling back to **argument** types with
untyped arguments defaulting to `i32`. Parameter and argument types diverge
exactly where FLang inserts a coercion, and a divergence emits a call to a
symbol nothing defines.

## Decision

**Lowering assigns symbols; backends emit them verbatim.** This binds the
**self-hosted compiler**, which is the implementation being carried forward.

**The C# reference compiler is exempt, permanently.** Its behaviour is recorded
above so the deviation is understood, not so it will be migrated. The migration
would touch three projects and reconcile two independently-derived manglings —
real work, on a codebase whose role is to bootstrap its replacement and then
retire. The hazard is latent (the harness is green), the compiler is not the
target for further investment, and the effort is better spent on the self-hosted
pipeline. Should a latent divergence ever surface as a link error, the fix is to
set `CalleeIrParamTypes` at the offending call site, not to restructure the
layer.

This is the general rule for the project: **specifications bind the self-hosted
compiler.** The C# compiler is the semantic reference for *what programs mean*,
not a model of *how the compiler should be structured*. Where the two disagree
on structure, the spec follows the self-hosted implementation.

## The self-hosted scheme

Because this is the implementation that must be right, its scheme is fixed here
rather than left to the code.

A symbol is a `__`-joined sequence of **escaped segments**: the module path
segments, the function name, then one token per parameter type.

- **Escaping**: a literal `_` in a source identifier is written `_0`. A lone `_`
  therefore never occurs inside a segment, so the `__` produced by joining is
  unambiguously a separator. (`flang_typer.checker::deinit` →
  `flang_0typer__checker__deinit`.)
- **Type tokens**: primitives by name; `&T` as `ref_<T>`; `[T; N]` as
  `arr<N>_<T>`; tuples as `tup_<T…>`; nominals by their escaped FQN — which
  carries dots, so it escapes the same way a module path does — with type
  arguments appended; `void`/`never` by name.
- **Exemptions**: the entry point (`main`) and `#foreign` functions keep their
  source spelling — both name symbols fixed outside the compiler.

Parameter types are included so that **overloads separate without a counter**.
The previous implementation appended a positional ordinal (`__2`, `__3`) assigned
during the lowering walk. That satisfied uniqueness but not determinism in any
useful sense: a symbol depended on how many same-named functions the walk had
already seen, so inserting a function silently renamed later ones, and separate
compilation would need a shared counter to agree. Deriving the symbol from the
function's own signature makes it a property of the function, which is what
"deterministic" has to mean for it to be worth anything.

## Consequences

**Good.** Symbols are a pure function of (module, name, parameter types).
Overloads separate without global ordering, which is what separate compilation
will need. `disambiguate` and its walk-order dependence are deleted. The backend
contract stays one line.

**Cost.** Symbols get longer and less readable for functions with many
parameters. Accepted: they are debugging surface, not source, and the previous
scheme's brevity was paid for with order-dependence.

**Known gap.** Generic specializations are not yet distinguished — the
self-hosted compiler does not monomorphise yet. When it does, the specialized
type arguments must join the token list, or two specializations of one generic
will collide. This is the one place the scheme is knowingly incomplete, and it
must be closed as part of the generics milestone rather than after it.

**Residual ambiguity.** A source function whose name collides with a generated
type token (a function literally named `ref_0i32`) could in principle alias a
different function's symbol. Escaping makes this require deliberate effort, and
no diagnostic exists for it. Noted rather than solved.
