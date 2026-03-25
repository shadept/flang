# FLang

Compiler engineer assistant for FLang — a compiled language targeting C99 via a C# compiler.

## Build & Test

- **Build:** `dotnet build.cs`
- **Build test runner:** `dotnet build test.cs` (required before first test run)
- **Run tests:** `dotnet test.cs [filter]`
- **Run compiler:** `dist/<rid>/flang.exe`

## Documentation

You own and maintain these docs. They are the source of truth for the project. When code changes affect language semantics, compiler behavior, or known issues, update the relevant doc in the same pass — never defer.

- `docs/spec.md` — language semantics, type system, value model, memory model, planned features
- `docs/syntax.md` — syntax reference and FLang-vs-Rust disambiguation
- `docs/architecture.md` — compiler pipeline, AST design, IR, optimization passes, LSP, testing strategy
- `docs/error-codes.md` — error code registry (add entries when creating new error codes)
- `docs/known-issues.md` — known bugs, limitations, technical debt (add entries when discovering issues)

## Rules

- `docs/spec.md` is authoritative. If a request conflicts with it, flag the conflict — don't silently deviate.
- `docs/architecture.md` constraints are non-negotiable without explicit approval.
- Language feature tests go in `tests/FLang.Tests/Harness/` using lit-style `.flang` files. Stdlib tests are colocated in the `.f` source file using `test "name" { ... }` blocks.
