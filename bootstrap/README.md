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

- [x] Project skeleton + dependency on `flang_parser` and `flang_core`
- [x] CLI argument parsing via `std.env.getopts`
- [x] Subcommand dispatch (`build`, `fmt`, `lsp`, `cst`, `tokens`)
- [x] Trivia-attached lexer (`flang_parser.lexer.tokenize`)
- [x] Structured CST (decls, blocks, expressions, patterns)
- [x] `flang_fmt` round-trip + trivia normalization (in-place rewrite)
- [x] `dump_tokens` debug tool for the lexer
- [x] AST projection (`flang_parser.projector.project_module`)
- [ ] Codegen library (FIR + backends — see "Strategy" below)
- [ ] Name resolution + symbol tables
- [ ] Hindley-Milner type inference
- [ ] Lowering to FIR
- [ ] Self-host

## Status

The frontend stack (lex → CST → AST) is complete in flang. `flang_fmt`
round-trips every bootstrap source file byte-identical. `cst_explorer`
emits a JSON dump of source + tokens + CST + AST + diagnostics, consumed
by `cst_explorer_web` for visualization. The `bootstrap` CLI parses args
and dispatches to sibling tools; the `build` subcommand is still a stub.

The C# reference compiler (`src/FLang.*`) is the source of truth for
semantics today. The self-host work is being done outside-in: pull each
stage out as a reusable library, validate it under the existing pipeline,
then wire it into `bootstrap build`.

## Strategy

Stages are split into reusable libraries (`lib/flang_parser`,
`lib/flang_core`, future `lib/flang_codegen`) so each piece is testable
in isolation and reusable by tools (`cst_explorer`, `flang_fmt`, LSP).
The hard work — type inference, FIR lowering — stays in the bootstrap
crate until it stabilises, then moves out.
