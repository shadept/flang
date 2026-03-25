# FLang Compiler Architecture

## Compilation Pipeline

```
Source → Lexer → Parser → Source Generators → HmTypeChecker → HmAstLowering (FIR) → Optimizations → HmCCodeGenerator → C99 → GCC/Clang → Native
```

All phases communicate through a central `Compilation` context object — phases never reference each other directly. `Compilation` owns source files, type registries (structs, enums, specializations), module metadata, and global constants.

## AST Design

- **Top-down only.** No parent pointers. Context is passed down during traversal, never looked up.
- **Two-phase properties:** Parser creates immutable syntactic data (names, operators, structure). `HmTypeChecker` later writes mutable semantic fields (resolved types, targets, operators). Semantic fields are nullable, null until type checking.
- **Analysis logic lives in dedicated solvers/visitors**, never in AST node methods.

## Type System

- **`InferenceEngine`** handles type unification and resolution. Short-lived per function scope. Holds active generic substitutions. Coercion rules (e.g., `u8` → `u16`, `comptime_int` → `i32`) are implemented via `IInferenceCoercionRule`.
- **Eager monomorphization.** Generic functions are instantiated with concrete types during type checking. `HmTypeChecker.EnsureSpecialization()` deep-clones the generic body, substitutes type parameters, and type-checks the specialization. Generic templates never reach IR.
- **Iterator protocol:** Any type used in `for` must have `iter()` returning a type with `next()` returning `Option[E]`.
- **`TypeLayoutService`** computes memory layouts (alignment, offsets) for struct types, used by lowering for implicit reference passing of large values.

## Intermediate Representation (FIR)

Linear IR: `IrModule` → `IrFunction` → `BasicBlock` → `Instruction`. Merge points use phi-via-alloca (allocate slot, store from each branch).

Complex constructs (`for`, `if` expressions, `defer`, `match`) are desugared into basic blocks and branches during AST → FIR lowering.

## Optimization Passes

- **Inlining** (`InliningPass`): Multi-pass function inlining with cascading until no opportunities remain.
- **Peephole** (`PeepholeOptimizer`): Store-load forwarding, copy fusion, dead code elimination.

Both run iteratively between lowering and codegen.

## C99 Backend

- **Name mangling only in codegen.** IR preserves base function names. `HmCCodeGenerator` applies `IrNameMangling.MangleFunctionName()` when emitting C. `main` is never mangled.
- **Foreign/intrinsic symbols are not mangled.** `#foreign` and `#intrinsic` calls use their declared names directly.
- **Intrinsics declared in `stdlib/core`** with `#intrinsic` directive.

## Source Generators

`TemplateExpander` (referred to as "source generators") runs between type collection and resolution. Generates source-level expansions (e.g., operator overloads, protocol implementations) before type checking.

## Compile-Time Context

`Compilation.CompileTimeContext` provides platform/OS/arch/runtime values for `#if` directive evaluation during parsing.

## Language Server (LSP)

The compiler includes an in-process LSP server (`FLang.Lsp`) invoked via `--lsp`. It reuses the same compilation pipeline — parser, source generators, type checker — so editor diagnostics match compiler output exactly. Features: hover, go-to-definition, type definition, document symbols, inlay hints (inferred types), signature help, and live diagnostics. `FLangWorkspace` manages document state with incremental re-analysis on file changes.

## Diagnostics

All phases report errors via `Diagnostic` objects with `SourceSpan` locations. Phases add diagnostics and continue when possible — exceptions are not used for user-facing errors. The CLI aggregates and prints diagnostics before exiting.

## Testing

Data-driven lit-style tests. Self-contained `.f` files with embedded metadata:

```flang
//! TEST: test_name
//! EXIT: 0
//! STDOUT: expected output
//! STDERR: expected error
//! COMPILE-ERROR: E0001
//! COMPILE-WARNING: W0001
//! SKIP: reason
```

The harness compiles and runs each test, asserting exit code, stdout, and stderr match metadata. `COMPILE-ERROR`/`COMPILE-WARNING` tests assert compilation fails or warns with the specified error code.

**Test placement:** Language feature tests go in `tests/FLang.Tests/Harness/`. Stdlib tests are colocated in `.f` source files using `test "name" { ... }` blocks.
