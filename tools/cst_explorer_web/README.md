# cst_explorer_web

Browser-based CST visualiser for FLang — astexplorer-style. Loads a
JSON dump produced by `cst_explorer --json` (the FLang CLI tool under
`tools/cst_explorer/`) and renders an interactive syntax tree
side-by-side with the source.

## Workflow

```sh
# 1. Emit a CST dump from any .f file
flang cst --json examples/hello-world/src/main.f > /tmp/hello.json

# 2. Open the viewer
cd tools/cst_explorer_web
npm install
npm run dev   # → http://localhost:5173
```

In the browser:

- Drop the `.json` file onto the page (or click to pick).
- Hover a token in the source pane → it highlights and shows kind/range.
- Click a tree node → the corresponding source range lights up; ancestor
  nodes auto-expand and the row scrolls into view.
- Diagnostics (parse errors) collapse into a panel at the bottom and
  underline the offending range in the source pane. Click a diagnostic
  to focus its range.

`?sample=1` in the URL auto-loads the bundled `public/sample.json`
(generated from `examples/hello-world`).

## Building a static bundle

```sh
npm run build      # → dist/
npm run preview    # serve dist/ on port 4173
```

The build is self-contained — drop `dist/` on any static host (or just
open `dist/index.html` directly, since Vite is configured with
`base: './'`).

## Data shape

See `src/lib/dump.js`. The CLI emits:

```jsonc
{
  "file": "/abs/path.f",
  "source": "raw source",
  "tokens": [
    { "kind": "Pub", "offset": 0, "line": 0, "text": "pub",
      "leading": [...], "trailing": [...] }
  ],
  "tree": {
    "kind": "Module", "start": 0, "end": 68,
    "children": [{ "node": {...} } | { "token": <index> }]
  },
  "diagnostics": [
    { "code": "E1001", "message": "...", "start": 0, "length": 3 }
  ]
}
```

The viewer indexes the tree (assigning a stable id to each node) and
resolves `{ "token": N }` references to the matching entry in `tokens`.

## Stack

Svelte 5 + Vite 6. No runtime dependencies — the entire viewer is a
~50 KB compiled JS bundle.
