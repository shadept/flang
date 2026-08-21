# bootstrap

The FLang compiler, written in FLang. Self-hosting target: stage-2
compiles itself byte-for-byte identical to stage-3.

## Build

```
flang build           # run from inside bootstrap/
```

Invokes the stage-0 compiler, resolves dependencies declared in
`flang.toml`, and emits `build/bootstrap[.exe]`.

## Structure

```
src/main.f       — CLI entry point
```

## Roadmap

The detailed, per-feature coverage matrix lives in
[`docs/self-host.md`](../docs/self-host.md) — the source of truth for
what lowers, what refuses, and what's next. High level:

- [x] Frontend: lexer, CST, `flang_fmt` round-trip, AST projection
- [x] Codegen library (`lib/flang_codegen`: FIR + C backend)
- [x] Name resolution + symbol tables
- [x] Hindley-Milner type inference (`lib/flang_typer`, 0 `-c` errors)
- [ ] Lowering to FIR (see the matrix; scalars through aggregates done)
- [ ] Self-host

## Status

The frontend stack (lex → CST → AST) is complete in flang. `flang_fmt`
round-trips every bootstrap source file byte-identical. `cst_explorer`
emits a JSON dump of source + tokens + CST + AST + diagnostics, consumed
by `cst_explorer_web` for visualization.

`bootstrap build` runs end-to-end: it resolves the project, type-checks
it with `flang_typer` — 0 `-c` errors across the compiler + stdlib
(99 modules) — lowers to FIR via `flang_driver`, and emits native
executables through `flang_codegen`, linking the stdlib's C runtime
sidecars. As of M11 (2026-08-21) the full self-build LINKS: **stage-1
exists** and compiles + runs single-file programs correctly. 15
functions still refuse (all off `main`'s path — SIMD csv internals and
a few IO helpers); refusal-over-miscompile still guards them. Stage-1
segfaults on the full multi-module project build — that miscompile hunt
is the stage-2 frontier (docs/known-issues.md). `-v` prints a
per-function skip report with reasons.

The C# reference compiler (`src/FLang.*`) is the source of truth for
semantics today.

## Strategy

Stages are split into reusable libraries so each piece is testable in
isolation and reusable by tools (`cst_explorer`, `flang_fmt`, LSP):
`lib/flang_parser` (lex → CST → AST), `lib/flang_core` (shared
primitives), `lib/flang_typer` (type inference), `lib/flang_codegen`
(FIR + C backend), and `lib/flang_driver` (name resolution, AST → FIR
lowering, project builds). The bootstrap crate is just the CLI shell
over these libraries.
