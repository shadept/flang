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
- **`op_deref` fallback:** When `ResolveFieldAccess()` can't find a field on a nominal type, or when UFCS call resolution fails, the compiler tries `TryResolveOperator("op_deref", [&Type])`. For field access, the resolved function is appended to `MemberAccessExpressionNode.OpDerefChain`. For UFCS calls, the chain is stored in `CallExpressionNode.UfcsOpDerefChain`. Lowering replays the chain as function calls before the field GEP or function call.

## Intermediate Representation (FIR)

Linear IR: `IrModule` → `IrFunction` → `BasicBlock` → `Instruction`. Merge points use phi-via-alloca (allocate slot, store from each branch).

Complex constructs (`for`, `if` expressions, `defer`, `match`) are desugared into basic blocks and branches during AST → FIR lowering.

## Optimization Passes

- **Inlining** (`InliningPass`): Multi-pass function inlining with cascading until no opportunities remain.
- **Peephole** (`PeepholeOptimizer`): Store-load forwarding, copy fusion, dead code elimination.

Both run iteratively between lowering and codegen.

### Future IR optimizations

The following are redundancies in the generated IR that Clang eliminates at `-O2` but could be addressed in FIR for better unoptimized debug builds and reduced C output size. `match_arm_control_flow.f` is a good test case — Clang collapses `loop_break()` to `ret i32 33` and `early_return()` to a branchless `select`.

- **Constant enum construction:** `Action.Stop` (payload-less) generates 3 allocas + load + store; could emit a single constant struct.
- **Redundant scrutinee copy:** match lowers the scrutinee into a second alloca for tag extraction even when the original is already addressable.
- **Dead block elimination:** `break`/`continue`/`return` in expression position emit a `dead` basic block for subsequent unreachable code; these could be pruned.
- **Dead stores / unused allocas:** DCE removes allocas with zero uses, but allocas that are only stored to (never loaded) survive because `StorePointerInstruction` is not side-effect-free, keeping the alloca alive. Requires dead-store elimination: detect allocas that are stored to but never loaded, then remove both the stores and the alloca.

## C99 Backend

- **Name mangling only in codegen.** IR preserves base function names. `HmCCodeGenerator` applies `IrNameMangling.MangleFunctionName()` when emitting C. `main` is never mangled.
- **Foreign/intrinsic symbols are not mangled.** `#foreign` and `#intrinsic` calls use their declared names directly.
- **Foreign structs skip codegen.** `IrStruct.IsForeign` structs have no typedef or definition emitted — the `#include` of the original C header provides them. Their `CName` is the original C name (e.g. `Color`), not mangled.
- **Intrinsics declared in `stdlib/core`** with `#intrinsic` directive.

## C FFI Binding Generation

The compiler can parse C headers and generate FLang bindings via the `-I` flag:

```
flang -I raylib.h -L libraylib.a main.f
```

**Pipeline:** CLI receives `-I <header>` → `ICHeaderParser` (CppAst implementation) parses the header → `FLangBindingGenerator` produces FLang source → written to `vendor/<name>.f` → module compiler discovers it via `import vendor.<name>`.

**Architecture:**
- `ICHeaderParser` (`src/FLang.CLI/FFI/`) is an abstraction interface returning intermediate model types (`CFunction`, `CStruct`, `CEnumConstant`). The CppAst implementation can be swapped.
- `FLangBindingGenerator` converts the intermediate model to FLang source text.
- C pointers map to `Option(&T)`. C enums map to `pub const: i32`. C structs map to `#foreign struct`.
- Foreign header paths propagate through `IrModule.ForeignIncludes` and are emitted as `#include` directives in the generated C code.

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
