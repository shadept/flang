# bootstrap

The FLang compiler, written in FLang. Self-hosting target: stage-2
compiles itself byte-for-byte identical to stage-3.

## Build

```
flang build           # run from inside bootstrap/
```

Invokes the stage-0 compiler, resolves dependencies declared in
`flang.toml`, and emits `build/bootstrap[.exe]`.

From the repo root, `build.cs` drives the whole chain:

```
dotnet build.cs                 # reference -> stage 1 (dist/<rid>/flang)
dotnet build.cs -- --stage2     # + stage 1 compiles the compiler again
dotnet build.cs -- --stage3     # + stage 3, and check the fixpoint
```

Every stage is built `--release`. It is not a detail: an unoptimized
compiler takes ~4.8x longer to compile anything (13.4s vs 2.8s for this
project), and the whole chain plus both self-build stages runs in ~23s.
Windows keeps debug info either way (`/Z7` is passed in both modes).

`flang build -t` prints where the wall time went, one line per phase, with
the typechecker broken down beneath it. Options follow the command.

Stage artifacts land in `dist/<rid>/stages/` as `stage{2,3}{.exe,.c}`. The
fixpoint check byte-compares the two `.c` files — binaries carry timestamps
and paths, the emitted C does not. Each stage runs
`flang build -k -s <repo>/stdlib`: `-k` keeps the generated C, `-s` points a
compiler living outside `dist/<rid>/` at the stdlib.

## Structure

```
src/main.f       — CLI entry point
```

## Dependencies

```
        flang_core        flang_codegen
         ^      ^              ^
         |      |              |
  flang_parser  |              |
         ^      |              |
         |      |              |
    flang_typer |              |
         ^   ^  |              |
         |   |  |              |
         | flang_analysis      |
         |   ^                 |
         |   |                 |
        flang_driver ──────────┘
             ^
          bootstrap
```

## Roadmap

The detailed, per-feature coverage matrix lives in
[`docs/self-host.md`](../docs/self-host.md) — the source of truth for
what lowers, what refuses, and what's next. High level:

- [x] Frontend: lexer, CST, `flang_fmt` round-trip, AST projection
- [x] Codegen library (`lib/flang_codegen`: FIR + C backend)
- [x] Name resolution + symbol tables
- [x] Hindley-Milner type inference (`lib/flang_typer`, 0 `-c` errors)
- [x] Lowering to FIR (see the matrix; 15 off-path refusals remain)
- [x] Self-host (stage-2 = stage-3 byte-identical fixpoint, 2026-08-22;
      template expansion still rides the `.generated.f` sidecars)

## Status

The frontend stack (lex → CST → AST) is complete in flang. `flang_fmt`
round-trips every bootstrap source file byte-identical. `cst_explorer`
emits a JSON dump of source + tokens + CST + AST + diagnostics, consumed
by `cst_explorer_web` for visualization.

`bootstrap build` runs end-to-end: it resolves the project, type-checks
it with `flang_typer` — 0 `-c` errors across the compiler + stdlib
(99 modules) — lowers to FIR via `flang_driver`, and emits native
executables through `flang_codegen`, linking the stdlib's C runtime
sidecars. As of 2026-08-22 the **stage-2 = stage-3 byte-identical
fixpoint is reached**: stage-1 builds the full project into stage-2,
stage-2 builds stage-3, and the two emit identical C. 15 functions
still refuse (all off `main`'s path — SIMD csv internals and a few IO
helpers); refusal-over-miscompile still guards them. `-v` prints a
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
