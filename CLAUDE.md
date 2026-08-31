# FLang

Compiler engineer assistant for FLang — a compiled language targeting C99, compiled by a self-hosted compiler written in FLang.

## Build & Test

- **Build:** `dotnet run build.cs` (builds with `dist/<rid>/flang`, else the `boot/<rid>` seed; a clean clone cold-starts from the seed, see `boot/README.md`)
- **Run tests:** `dotnet test.cs [filter]` (language-feature harness; compiles each test by subprocessing `dist/<rid>/flang`, or `$FLANG`)
- **Run colocated `test {}` blocks:** `dotnet test-all.cs`, or `flang test [path] [--name <substr>]` from a project directory
- **CLI shape:** `flang <command> [options] [args]` - the command comes first and options are parsed against it (`flang build -r`, not `flang -r build`)
- **Type-check only:** `flang check` (includes `test {}` bodies; `flang build --check` does not)
- **Run compiler:** `dist/<rid>/flang.exe`
- **Format:** `dist/<rid>/flang.exe fmt` from a project directory (`--check` writes nothing, exits 1 on drift). Style and `[fmt]` knobs: see `docs/architecture.md` §Formatter.
- **After tests pass, run `flang fmt` before finishing** on every project you touched (`compiler/`, each `lib/*`, `tools/*`; for `stdlib/` pass the changed `.f` files as arguments - it has no manifest). A task is not done with formatting drift.

## Documentation

You own and maintain these docs. They are the source of truth for the project. When code changes affect language semantics, compiler behavior, or known issues, update the relevant doc in the same pass — never defer.

- `docs/spec.md` — language semantics, type system, value model, memory model, planned features
- `docs/syntax.md` — syntax reference and FLang-vs-Rust disambiguation
- `docs/architecture.md` — compiler pipeline, AST design, IR, optimization passes, LSP, testing strategy
- `docs/error-codes.md` — error code registry (add entries when creating new error codes)
- `docs/known-issues.md` — known bugs, limitations, technical debt (add entries when discovering issues)
- `docs/self-host.md` — self-host feature coverage matrix and milestone roadmap (update in the same commit as any lowering-coverage change)

## Rules

- **Seed rule.** Compiler (`compiler/`), `lib/*`, and `stdlib/` sources may only use language features the committed seed in `boot/` supports. New feature order: implement, harness-test, promote (`dotnet run promote.cs`), then use. Never edit `boot/` by hand; promote is the only writer, and each promote is its own commit tagged `seed/<YYYYMMDD>` — one tag per date, moved when a second promote lands the same day. See `docs/architecture.md` §Bootstrap Seed.

- `docs/spec.md` is authoritative. If a request conflicts with it, flag the conflict — don't silently deviate.
- `docs/architecture.md` constraints are non-negotiable without explicit approval.
- Language feature tests go in `tests/harness/` using lit-style `.f` files. Stdlib tests are colocated in the `.f` source file using `test "name" { ... }` blocks.
- `test {}` bodies are checked only when the demand asks for it (`flang test`, `flang check`, the LSP). A plain `flang build` does not look inside them, so a test-only type error will not fail a build - run `flang check` before calling a change done.
- **Default to inference.** Omit any type annotation the checker can work out, in FLang code and in the stdlib alike. A free type variable in a return position is a working feature, not a gap: `let l = list(3)` followed by `l.push(3i32)` resolves to `List(i32)`, and an unsuffixed literal pushed first resolves the same way. Annotate only where inference has no source to draw from.
- **Library layout.** `flang.toml [project].name` is the import namespace; files under `src/` sit directly in it. `lib/flang_parser/src/ast.f` is `import flang_parser.ast`. Never nest a `src/<name>/` folder.
- **Harness tests are the exception: annotate.** A test should pin the types it means, so a failure reports the behaviour under test rather than an inference change somewhere upstream. Tests whose subject IS inference are written the other way round, leaving the types to be worked out.

## Anti-Patterns to Avoid

- **Blind implementation:** Never write code based on assumptions about what exists. Always verify first.
- **Pattern guessing:** Don't assume a codebase follows common patterns. Read actual code to confirm.
- **Inventing APIs:** Never call methods/classes that might not exist. Search for them first.
- **Copying from memory:** Don't reproduce code from similar projects. This project has its own patterns.

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
