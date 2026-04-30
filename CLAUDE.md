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

## Core Priorities

- **Performance first.** Keep compile times in check, avoid unnecessary allocations in hot paths, and watch for accidental O(n²) behavior in compiler passes and generated C.
- **Reliability first.** Keep behavior predictable under malformed input and edge cases. Handle error paths explicitly; never leave the compiler in an ambiguous state or emit silently-wrong C.
- If a tradeoff is required, choose correctness and robustness over short-term convenience.

## Maintainability

Long term maintainability is a core priority. If you add new functionality, first check if there is shared logic that can be extracted to a separate module. Duplicate logic across multiple files is a code smell and should be avoided. Don't be afraid to change existing code. Don't take shortcuts by just adding local logic to solve a problem.

## Agent skills

### Issue tracker

Issues live as markdown files under `.scratch/<feature>/` in this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
