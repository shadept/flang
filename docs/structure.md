# FLang Project Structure (.NET Solution)

The solution is divided to enforce strict separation of concerns and allow for modular backend replacement.

## 1. `FLang.Core` (Class Library)

- **Role:** Shared definitions used by _all_ other projects.
- **Contains:**
  - `Source`, `SourceSpan`, `SourceLocation` definitions.
  - Common diagnostic (error/warning) enums and structures.
  - Basic configuration/options objects.

## 2. `FLang.Frontend` (Class Library)

- **Role:** Converting text into a structured AST.
- **Dependencies:** `FLang.Core`
- **Contains:**
  - **Lexer:** High-performance, operates on `ReadOnlySpan<char>`.
  - **Parser:** Produces the AST.
  - **AST Definitions:** The class hierarchy for all language nodes (`Expression`, `Statement`, `Declaration`, etc.).

## 3. `FLang.Semantics` (Class Library)

- **Role:** Meaning, validation, and type inference. (Formerly "Backend" shared code).
- **Dependencies:** `FLang.Frontend`, `FLang.Core`
- **Contains:**
  - **Type Definitions:** `TypeDefinition`, `StructType`, `FunctionType`, etc.
  - **`TypeSolver`:** The unification and inference engine.
  - **Semantic Analysis Passes:** Declaration collector, Type-checker.
  - **FIR Generation:** Translating AST to the Linear SSA IR.

## 4. `FLang.IR` (Class Library)

- **Role:** Defines the Intermediate Representation and optimizations on it.
- **Dependencies:** `FLang.Core`
- **Contains:**
  - **FIR Definitions:** `Module`, `Function`, `BasicBlock`, `Instruction` (SSA-style with Block Args).
  - **Optimization Passes:** (Future) Constant folding, DCE, inlining.

## 5. `FLang.Codegen.C` (Class Library)

- **Role:** The initial concrete backend implementation.
- **Dependencies:** `FLang.IR`, `FLang.Core`
- **Contains:**
  - Implementation of `ICodeGenerator` that walks the FIR and emits C99 source code.

## 6. `FLang.CLI` (Console Application)

- **Role:** The user-facing entry point. Orchestrates the pipeline.
- **Dependencies:** All of the above.
- **Responsibilities:**
  - Parsing command line arguments.
  - Initializing the `Compilation` context.
  - Running the Frontend -> Semantics -> IR -> Codegen pipeline.
  - Emitting human-readable errors to Stderr.

## 7. `FLang.Tests` (Unit Test Project)

- **Role:** End-to-end integration testing harness.
- **Dependencies:** `FLang.CLI` (referenced as a tool or library to invoke).
- **Responsibilities:**
  - Discovers `.flang` test files with embedded `//!` metadata.
  - Compiles and runs them, verifying exit codes, stdout, and stderr.

## 8. Standard Library (`lib/`)

- **Role:** The core FLang code distributed with the compiler.
- **Location:** A physical `lib/` folder relative to the compiler binary.
- **Structure:**
  - `core/`: Bare-metal essentials (`syscalls.f`, raw `mem.f`).
  - `std/`: Higher-level standard libraries.
    - `collections/`: `list.f`, `dict.f`.
    - `text/`: `string.f` (defines built-in `String`), `string_builder.f`.
    - `io.f`, `os.f`, `math.f`.
