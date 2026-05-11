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
- [x] Subcommand dispatch (`build`, `fmt`, `lsp`)
- [x] Trivia-attached lexer (`flang_parser.lexer.tokenize`)
- [x] Flat-Module CST construction (`flang_parser.parser.parse_module`)
- [x] `flang_fmt` round-trip + trivia normalization (in-place rewrite)
- [x] `dump_tokens` debug tool for the lexer
- [ ] Structured CST (decls, blocks, expressions) — currently flat
- [ ] AST projection
- [ ] Type checker
- [ ] Lowering
- [ ] C codegen
- [ ] Self-host

## Status

`flang_fmt` walks the CST and applies trivia-only normalization:
CRLF/CR → LF, trailing horizontal whitespace stripped, runs of 3+ newlines
collapsed to 2, single trailing newline. The 11 bootstrap source files
(`bootstrap/`, `lib/flang_parser/`, `lib/flang_core/`, `tools/flang_fmt/`,
`tools/dump_tokens/`) round-trip byte-identical through fmt — once a file
is normalized, fmt is a fixed point.

The parser currently produces a flat Module: every token becomes a direct
child. That's enough for trivia-only normalization. Real grammar rules
(imports → decls → expressions) land once the formatter needs structural
information (indentation rewriting, expression alignment).
