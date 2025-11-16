# FLang Compiler Architecture (v2)

## 1. Core Design Principles

- **Context is King:** Phases do not operate in a vacuum. They are managed by a central `Compilation` context.
- **Async-First Orchestration:** The `Compilation` context must be thread-safe from Day 1 to support future concurrent file parsing.
- **Separation of Concerns (Data vs. Logic):** AST nodes are dumb data containers. Logic lives in dedicated "Solvers" or "Visitors".
- **No Parent Pointers:** The AST is a strictly top-down tree. Context is passed down during traversal, never looked up.
- **Standard Tools:** Use standard .NET BCL types (`string` for identifiers, `List<T>` for collections, `ReadOnlySpan<char>` for lexing). Do NOT reinvent basic data structures.

## 2. Key Data Structures

### 2.1 `Source` & `SourceSpan`

- **`Source` (Class):** Immutable representation of a single source file. Holds the full text string and pre-calculated line ending offsets.
- **`SourceSpan` (Struct):** A lightweight, 12-byte "pointer" to a location.
  ```csharp
  public readonly record struct SourceSpan(int FileId, int Index, int Length);
  ```
  - It does NOT hold a reference to the `Source` object.
  - It does NOT hold the string text.

### 2.2 The AST

- Nodes hold their owned data as standard C# types (e.g., `IdentifierExpression` holds a `string Name`).
- Every node holds a `SourceSpan` for error reporting.
- **`BinaryOperator`:** A wrapper struct around a `Token` and a `BinaryOperatorKind` enum for easy semantic processing.
- **`DeclarationFlags`:** A `[Flags]` enum for modifiers like `Public`.

## 3. Key Components

### Diagnostics Across Phases

- All compiler phases (lexer, parser, semantics, lowering) report issues via `FLang.Core.Diagnostic`.
- Phases should avoid throwing exceptions for user-facing errors; instead, add diagnostics with precise `SourceSpan`s and continue when possible.
- The CLI aggregates diagnostics from module loading, parsing, type checking, and lowering, then prints them using `DiagnosticPrinter` before exiting.

### 3.1 `Compilation` (Orchestrator)


- Owns the master list of `Source` objects (`List<Source>`) and assigns atomic `FileId`s.
- Manages the work queue for parsing (handling `import` statements concurrently in the future).
- Uses a thread-safe dictionary to deduplicate imports.

### 3.2 `TypeSolver` (The Heart of Semantics)

A short-lived, stateful object created to type-check a single function or expression scope.

- **State:** Holds the active generic substitutions (e.g., `Dictionary<string, TypeDefinition>`).
- **Responsibilities:**
  - **`Resolve(Type)`:** recursively follows substitutions to find the concrete type.
  - **`TryUnify(Type A, Type B)`:** Checks for _structural equality_ and binds generic placeholders.
  - **`IsAssignableFrom(Type Target, Type Source)`:** Checks for _coercion_ (e.g., `u8` -> `u16`, or `comptime_int` -> `i32`).
- **Iterator Protocol:** Enforces that any type used in a `for` loop has an `iterator()` method returning a type with a `next()` method.

### 3.3 FLang Intermediate Representation (FIR)

A Linear SSA (Static Single Assignment) IR based on Basic Blocks, similar to TACKY but with SSA properties.

- **Structure:** `Module` -> `Function` -> `BasicBlock` -> `Instruction`.
- **SSA:** Uses Block Arguments (instead of Phi nodes) for merge points.
- **Desugaring:** Complex high-level constructs (like `for` loops, `if` expressions, `defer`) are lowered into simple Blocks and Branches during the AST -> FIR translation phase.

## 4. Bootstrapping Strategy (The C-Transpiler)
 
To achieve self-hosting rapidly, v2 will NOT target machine code directly.
 
- **Target:** C99 (or similar portable C standard).
- **Benefit:** Leverages existing mature optimizers (GCC/Clang) and platform support immediately.
- **Workflow:** `FLang Source` -> `FLang Compiler` -> `FIR` -> `C Source` -> `GCC` -> `Native Executable`.

### Backend Responsibilities

- **Name mangling only in codegen:** TypeSolver and IR lowering must preserve base function names and attach type metadata. The C backend is solely responsible for producing unique C symbols (definitions, prototypes, and calls) by mangling non-foreign/non-intrinsic functions based on parameter types. `main` is not mangled.
- **Foreign and intrinsic symbols are not mangled:** Calls to `#foreign` and `#intrinsic` functions use their declared names. The backend relies on target headers or builtins for these symbols.
- **Intrinsics must be declared in stdlib core:** Compiler-recognized intrinsics are declared in `stdlib/core` with `#intrinsic` and may receive special lowering per target when required.


## 5. C# Implementation Guidelines

### 5.1 Modern C# Syntax

- Use modern C# features where they improve clarity: pattern matching, range operators (`[^1]`, `[2..]`), target-typed `new()`, file-scoped namespaces.
- Use `readonly struct` for small value types like `SourceSpan`, `BinaryOperator`.
- Records are available but not mandatory - use them where immutability is valuable.

### 5.2 Performance Considerations

Compilers are performance-critical software. Every design choice should consider hot paths (lexer loops, parser recursion, type checking, IR generation).

- **LINQ:**

  - **Avoid in hot paths:** Do NOT use LINQ in lexer, parser, code generation loops, or recursive visitors.
  - **Fine for cold paths:** LINQ is acceptable for one-time setup, configuration loading, or diagnostic collection.
  - **When in doubt:** Write explicit loops in performance-sensitive code.

- **Memory Efficiency:**

  - Prefer `ReadOnlySpan<char>` for text processing (lexing, substring operations).
  - Use `Span<T>` and `stackalloc` for small temporary buffers.
  - Consider `ArrayPool<T>` for larger reusable buffers.
  - Minimize allocations in tight loops - reuse collections where possible.

- **Modern BCL APIs:**
  - Use `CollectionsMarshal.AsSpan()` when you need direct access to `List<T>` internals.
  - Use `MemoryExtensions` methods (`AsSpan()`, `TrySplit()`, etc.) for string operations.
  - Prefer `StringBuilder` over repeated string concatenation.

### 5.3 Code Style

- **Clarity over cleverness:** Explicit code is better than terse code.
- **Defensive programming:** Validate inputs, check array bounds, assert invariants.
- **Focused methods:** Extract complex logic into well-named helper methods.
- **Avoid magic numbers:** Use named constants or enums.

## 6. Testing Strategy (Compiler Integration Tests)

We use a data-driven, "lit-style" testing framework rather than unit testing individual compiler components.

- **Test Files:** Self-contained `.flang` files with embedded metadata comments.
- **Metadata Format:**
  ```flang
  //! TEST: test_name
  //! EXIT: 42
  //! STDOUT: expected output line 1
  //! STDOUT: expected output line 2
  //! STDERR: expected error message
  ```
- **Harness:** The `FLang.Tests` project finds these files, invokes the `FLang.CLI` to compile and run them, and asserts that the actual exit code, stdout, and stderr match the metadata.
