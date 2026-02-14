# FLang Examples

Example projects that showcase FLang's capabilities and drive stdlib evolution.
Each example is a standalone project in its own directory with a `main.f` entry point.

## Roadmap

The examples follow a progression — each one builds on stdlib modules introduced
by the previous, culminating in `fq`, a fully-featured JSON query tool.

### Phase 1: `std.terminal`

ANSI escape code utilities: colors, cursor movement, screen clearing, styles.

| Example | Description | Stdlib modules |
|---------|-------------|----------------|
| `chess-fen` | Parse FEN strings and display Unicode chess boards | `std.string_builder` |
| `chess-fen-color` | Colored chess board with dark/light square backgrounds | `std.terminal` |
| `game-of-life` | Conway's Game of Life with animated terminal display | `std.terminal` |

### Phase 2: String Utilities

Core string operations: `split`, `find`, `trim`, `starts_with`, `contains`, `index_of`.

| Example | Description | Stdlib modules |
|---------|-------------|----------------|
| `rpn-calc` | Reverse Polish Notation calculator (`3 4 + 2 *` → `14`) | `std.string`, `std.terminal` |

### Phase 3: `std.encoding.json`

JSON parser, serializer, and pretty-printer.

| Example | Description | Stdlib modules |
|---------|-------------|----------------|
| `json-fmt` | JSON pretty-printer with syntax highlighting | `std.encoding.json`, `std.terminal` |

### Phase 4: CLI & I/O

Command-line argument parsing, stdin piping, robust file I/O.

| Example | Description | Stdlib modules |
|---------|-------------|----------------|
| `hexdump` | Hex dump utility (like `xxd`) | `std.cli`, `std.io` |

### Phase 5: `fq` — The Capstone

A `jq`-like JSON query tool combining every stdlib module.

| Example | Description | Stdlib modules |
|---------|-------------|----------------|
| `fq` | JSON query, filter, and transform with syntax highlighting | all of the above |

Features: dot-path queries (`.users[0].name`), pretty-print with colors, stdin
piping, file arguments, array filters, error reporting.

## Building & Running

```sh
# Build the compiler
dotnet run build.cs

# Compile an example
dist/osx-x64/flang build examples/chess-fen/main.f -o examples/chess-fen/chess-fen

# Run it
examples/chess-fen/chess-fen
```

## Future Ideas

Projects that could be added once the stdlib matures further:

- `base64` — Base64 encoder/decoder (→ `std.encoding.base64`)
- `toml-fmt` — TOML parser/formatter (→ `std.encoding.toml`, needed for `flang.toml`)
- `bf` — Brainfuck interpreter (exercises stdin, arrays, nested loops)
- `grep` — Simple pattern matcher (once string matching is robust)
