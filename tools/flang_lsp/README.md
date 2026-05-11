# flang_lsp

The FLang language server. Consumes `flang_parser` (for syntax) and
`flang_core` (for messages and code actions).

## Build

```
flang build           # from inside tools/flang_lsp/
```

## Use

```
build/flang_lsp       # speaks LSP JSON-RPC on stdio
```

## Doc comments

Leading `//` comments immediately preceding a declaration are surfaced
on hover and in completion items. Already the norm across `lib/` and
`bootstrap/`; this server is what makes them visible to editors.
