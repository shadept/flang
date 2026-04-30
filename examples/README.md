# FLang Examples

Example projects that showcase FLang's capabilities and drive stdlib evolution.
Each example is a standalone project with a `flang.toml` and a `src/` directory.

## Roadmap

The examples follow a progression — each one builds on stdlib modules introduced
by the previous, culminating in `fq`, a fully-featured JSON query tool.

### Phase 1: `std.terminal`

ANSI escape code utilities: colors, cursor movement, screen clearing, styles.

| Example | Description | Stdlib modules |
|---------|-------------|----------------|
| `chess-fen` | Parse FEN strings and display Unicode chess boards | `std.string_builder` |
| `chess-fen-color` | Colored chess board with dark/light square backgrounds | `std.terminal` |
| `snake` | Classic snake game with raw terminal input and game loop | `std.terminal` |
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
| `tree` | Recursive directory tree viewer (like `tree(1)`) | `std.io.fs`, `std.env`, `std.list`, `std.sort` |
| `hexdump` | Hex dump utility (like `xxd`) | `std.cli`, `std.io` |

### Phase 5: `fq`

A tiny `jq`-style JSON field selector focused on dot-path lookup.

| Example | Description | Stdlib modules |
|---------|-------------|----------------|
| `fq` | Query nested object fields with dot paths (`.user.name`) | `std.encoding.json`, `std.io.file`, `std.env` |

Features: dot-path queries (`.user.name`), stdin piping, file arguments,
pretty-printed JSON output.

## Building & Running

```sh
# Build the compiler
dotnet run build.cs

# Build an example (from the example directory)
cd examples/hello-world
flang build

# Run it
./build/hello-world
```

## Future Ideas

Projects that could be added once the stdlib matures further:

- `base64` — Base64 encoder/decoder (→ `std.encoding.base64`)
- `toml-fmt` — TOML parser/formatter (→ `std.encoding.toml`, needed for `flang.toml`)
- `bf` — Brainfuck interpreter (exercises stdin, arrays, nested loops)
- `grep` — Simple pattern matcher (once string matching is robust)
