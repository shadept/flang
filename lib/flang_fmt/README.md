# flang_fmt

The FLang source formatter, as a library. `compiler` runs it in-process
for `flang fmt`; anything else that needs formatting (the LSP's
format-on-save, tooling) imports the same implementation.

## API

Two calls:

```
let cfg = default_config()
set_option(&cfg, "max-width", "100")     // one [fmt] manifest entry; false = unknown key/value
format_source(source, &cfg)              // Result(OwnedString, FmtError) - pure, no IO
```

`FmtError.ParseFailed(n)` means the input does not parse (n diagnostics)
and nothing was formatted. `VerifyFailed` means the formatter produced
output it could not prove equivalent - a formatter bug; the input is
left untouched.

## How it works

The input is lexed and parsed to the lossless CST (see
`lib/flang_parser`); a single depth-first walk re-emits every token with
recomputed trivia. Token text is never touched. Structural line breaks
(between statements, inside brace bodies), blank lines, and comment
placement are the author's; breaks inside `(`/`[` groups and before
`and`/`or` are layout and re-flow to `max-width`. A comment-reflow text
pass re-fills own-line `//` prose paragraphs, leaving lists, rulers,
aligned columns, indented examples, and anything non-ASCII verbatim.

Formatting runs to an internal fixpoint (at most four passes). Before
any output is returned it is re-lexed and re-parsed: it must parse
cleanly, match the input token stream with commas set aside (the one
token separator policy may add or drop), and produce a parse tree of
identical shape. A formatter that fails this refuses the file rather
than change what the code means.

## Configuration

A `[fmt]` table in the project's `flang.toml`; every key optional.

| key | default | meaning |
|---|---|---|
| `indent` | `4` | spaces per indentation level |
| `max-width` | `100` | layout width; `0` disables wrapping, joining, reflow |
| `max-blank-lines` | `1` | maximum consecutive blank lines |
| `trailing-comma` | `"multiline"` | `no` / `multiline` / `always` |
| `separators` | `"no"` | same values; optional commas in struct/enum bodies and match arms |
| `join-lines` | `true` | re-flow layout breaks to `max-width` |
| `reflow-comments` | `true` | re-fill comment prose to `max-width` |
| `semicolons` | `"remove"` | `remove` / `keep` - `a(); b()` becomes one statement per line |
| `if-stmt` | `"multiline"` | `multiline` / `keep` - single-line statement `if x { ... }` (guards included) |
| `if-else-stmt` | `"multiline"` | same values - statement `if/else` |
| `if-expr` | `"keep"` | same values - `if` in expression position |

Full style semantics: `docs/architecture.md`, section "Formatter".

## Tests

Colocated `test` blocks in `src/fmt.f`:

```
flang test        # from inside lib/flang_fmt/
```
