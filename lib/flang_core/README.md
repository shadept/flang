# flang_core

Shared internal pieces every compiler tool depends on — source spans,
diagnostics, and the workspace-stable identifiers that tie tools to a
single source of truth.

## Why a separate library

`bootstrap`, `flang_fmt`, `flang_lsp`, and any future tool need to
produce and render diagnostics, and they all need to agree on what a
source location looks like. Putting these here means one definition;
adding a new severity, a new code-action shape, or changing rendering
rules happens in one place and every consumer picks it up on the next
build.

## Layout

```
src/
  span.f         — workspace-stable byte ranges
  diagnostic.f   — Severity, Diagnostic, simple constructors
```

## Consumers

- `bootstrap/`        — emits diagnostics from lexer/parser/type-checker/lowering
- `tools/flang_fmt/`  — surfaces parse-error diagnostics when input doesn't lex
- `tools/flang_lsp/`  — pushes diagnostics live to the editor
