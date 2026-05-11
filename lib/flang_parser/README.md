# flang_parser

The FLang lexer, parser, CST, and AST — extracted as a reusable library
so the bootstrap compiler, the formatter, the language server, and every
other tool consume the same implementation.

## Layout

```
src/
  trivia.f   — whitespace and comments attached to tokens
  token.f    — TokenKind + Token (text + offset + leading/trailing trivia)
  lexer.f    — Source → tokens (lossless)
  cst.f      — Concrete Syntax Tree (every byte reachable)
  parser.f   — Tokens → CstNode tree
  ast.f      — Semantic view over the CST
```

## Consumers

- `bootstrap/`            — the self-hosted FLang compiler
- `tools/flang_fmt/`      — source formatter
- `tools/flang_lsp/`      — language server
- `tools/dump_tokens/`    — debug tool / smoke test
