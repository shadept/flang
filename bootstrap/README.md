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
- [ ] Read input file → call `flang_parser.lexer.tokenize`
- [ ] CST construction (`flang_parser.parser.parse_module`)
- [ ] AST projection
- [ ] Type checker
- [ ] Lowering
- [ ] C codegen
- [ ] Self-host
