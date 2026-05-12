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
- `tools/dump_tokens/`    — debug tool: prints the lexer's token stream
- `tools/cst_explorer/`   — debug tool: prints the parser's CST tree (also `--json` for the web viewer)
- `tools/cst_explorer_web/` — browser SPA (Svelte+Vite) that visualises a `--json` dump

## CST shape

`parse_module()` returns a `CstNode { kind = Module, … }` whose children
are top-level declarations and the trailing `Eof` token. Every byte of
the source belongs to exactly one Token's leading trivia, text, or
trailing trivia — a depth-first walk that emits each Token's
`leading + text + trailing` reproduces the source verbatim. The
formatter (`tools/flang_fmt`) relies on this round-trip invariant; the
test sweep `tools/cst_explorer + flang_fmt` over the workspace confirms
zero parse errors and full byte-for-byte idempotency across the stdlib,
examples, and self-hosted libraries.

Recovery wraps unrecognised runs in `NodeKind.Error` subtrees that
still own their child tokens, so partial trees stay formatter-safe.
Parser diagnostics accumulate on `Parser.diagnostics` for tooling.
