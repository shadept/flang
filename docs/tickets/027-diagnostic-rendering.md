# RFC-027: Diagnostic rendering - source snippets, carets and color

**Type:** Compiler UX (CLI rendering)
**Status:** Landed 2026-08-30 - phases 1-5; deferred items unchanged
**Depends on:** None
**Relates to:** RFC-023 (language server, shares the line index), spec §7 (diagnostics)

## Summary

The self-hosted CLI prints a one-line diagnostic with no source context and no
color. The retired reference printed a framed snippet with a caret underline
under the offending range. Restore that, and put the renderer somewhere both the
compiler and future tools can reach.

1. **One renderer, in `flang_core`.** A pure function from (path, source, line
   index, diagnostic, style) to a string. No IO, no globals, so it is covered by
   colocated `test {}` blocks rather than golden files.
2. **Reuse what exists.** `std.terminal` already has `Color`, `Style`, `set_fg`,
   `set_style` and `reset` over a `Writer`, and `StringBuilder` is a `Writer`. No
   new ANSI enum.
3. **`LineIndex` moves down to `flang_core`.** The LSP has one, the renderer needs
   one, and `frontend.f` currently rescans the source from byte 0 per diagnostic.
4. **Color is auto-detected and overridable.** `--color=auto|always|never`,
   `NO_COLOR`, `TERM=dumb`, and a Windows virtual-terminal enable.
5. **Diagnostics go to stderr.** They go to stdout today.

## Motivation

Today, `compiler/src/frontend.f:37`:

```
lib/flang_typer/src/checker.f:1216:13: error[E2002]: expected `i32`, got `String`
  hint: annotate the binding
```

The line and column are correct and useless: reading the error means opening the
file and counting to column 13. The reference rendered this instead, which is
what the target is:

```
error[E2002]: expected `i32`, got `String`
  --> lib/flang_typer/src/checker.f:1216:13
   |
15 |     let total = 0
16 |     total = name
   |             ^^^^ expected `i32`, got `String`
17 | }
   |
```

Two costs beyond the reading experience. `line_col` scans the source from byte 0
for every diagnostic, so a file with many errors is quadratic in file size. And
diagnostics on stdout are interleaved with build progress on stdout, so neither
stream can be redirected on its own.

## Design

### 1. Module layout

| Module | Holds |
|---|---|
| `flang_core.line_index` | `LineIndex`, `line_index(text)`, `line_of`, `line_bounds` |
| `flang_core.render` | `render_diagnostic(...) OwnedString`, `RenderStyle` |
| `flang_lsp.line_index` | `Position`, `PositionEncoding`, `to_position`, `to_offset` over the core index |
| `compiler/src/frontend.f` | picks source by file id, resolves the style, writes to stderr |

`LineIndex` is moved, not copied: `lib/flang_lsp/src/line_index.f` keeps only the
LSP position codec, which is the half that knows about UTF-16.

The renderer is honest: everything it reads arrives through its signature, and it
returns a string rather than writing one. The terminal, the environment and the
file id lookup all stay in `frontend.f`.

```
pub type RenderStyle = struct {
    color: bool
    tab_width: usize
    context_lines: usize
}

pub fn render_diagnostic(path: String, source: String, idx: &LineIndex,
    d: &Diagnostic, style: &RenderStyle, alloc: &Allocator? = null) OwnedString
```

### 2. Layout

Reproduces the reference's frame:

- header `severity[CODE]: message`, severity and code in the severity's bold
  color, message in bold
- `  --> path:line:col` with the arrow in bold blue
- a gutter `NN | ` sized to the widest visible line number, in bold blue
- one context line before and after the span, the span's own lines between
- a caret run under the span in the severity's plain color, with `hint` appended
  after it when present
- a bare gutter line opening and closing the frame

Severity colors, unchanged from the reference: error bold red, warning bold
yellow, info bold cyan, hint bold green. Underlines take the non-bold variant.

A span with `file_id < 0` renders the header alone. A multi-line span underlines
each of its lines, full width for the interior ones, and carries the hint on the
last.

The reference's line terminator constant was `"\n\r"`, reversed. Use `"\n"`.

### 3. Caret placement

The caret column is a display column, not a byte offset. Two corrections the
reference did not make:

- a tab in the source line expands to `tab_width` spaces in the rendered line,
  and the caret run is computed against the expanded text
- the offset within the line counts UTF-8 codepoints, not bytes, so a comment or
  string literal above ASCII does not shift the carets

Codepoint counting is where this stops. East Asian width and combining marks are
out of scope: `std.encoding.utf8` gives the codepoint walk, nothing gives width.

### 4. Color policy

`--color` joins `SHARED_OPTS` in `compiler/src/main.f` as `C(color):`.

| Value | Behaviour |
|---|---|
| `never` | no escapes |
| `always` | escapes regardless of destination |
| `auto` (default) | escapes when stderr is a terminal, `NO_COLOR` is unset and `TERM` is not `dumb` |

`isatty` is declared `#foreign` in `stdlib/std/readline.f` and the Windows console
mode dance lives there too. Both move to `std.terminal`, which is where a caller
that is not a line editor can reach them:

```
pub fn is_tty(fd: i32) bool
pub fn enable_ansi()          // Windows: ENABLE_VIRTUAL_TERMINAL_PROCESSING, elsewhere a no-op
```

`readline.f` then calls them instead of holding its own copies.

The harness runs the compiler as a subprocess with redirected pipes, so `auto`
resolves to off and `ContainsDiagnostic` (`test.cs`, matching `[CODE]` and a
message substring) is unaffected. The header keeps `severity` and `[CODE]`
inside one colored run regardless, so the substring survives even under
`--color=always`.

### 5. Stream

`print_diagnostic` writes to `stderr`, not `println`. `test.cs` merges both
streams into `compilerOutput`, so harness expectations do not move.

## Testing

Colocated `test {}` blocks in `flang_core.render`, asserting the exact rendered
string with `color = false`:

- single-line span, caret run under the exact range, hint appended
- span at the first line and at the last line, where a context line is absent
- multi-line span, interior line underlined full width, hint on the last line
- `none_span()`, header only
- a line containing tabs, carets aligned against the expanded text
- a line containing non-ASCII, carets aligned by codepoint
- gutter width grows with the line number's digit count
- `color = true` emits the severity's escape around the header and nothing else
  around the source text

`flang_core.line_index` inherits the LSP module's existing index tests; the
position-codec tests stay with the codec.

No harness test: the harness matches diagnostic codes and message substrings, and
the frame is neither.

## Documentation

- `docs/architecture.md` gains a Diagnostics section describing the renderer seam
  and where color is decided.
- `README.md` and `flang --help` gain `--color`.
- `lib/flang_core/src/diagnostic.f`'s header claims code actions ship attached to
  the diagnostic. No such field exists. Correct the header in this pass.

## Implementation order

1. `LineIndex` down to `flang_core`, LSP re-imports it. No behaviour change.
2. `std.terminal` gains `is_tty` and `enable_ansi`; `readline.f` drops its copies.
3. `flang_core.render` with its tests, color off.
4. `frontend.f` on the renderer, output to stderr, `--color` wired through.
5. Tabs, codepoints, gutter widths.

Steps 1 and 2 are refactors that stand on their own; the renderer is the only
step that can change output.

No new language features, so no seed promote is needed.

## What actually landed

Phases 1-5 as designed, with three notes.

**The LSP re-exports the core index** (`pub import flang_core.line_index`) rather than every consumer
gaining a second import. A caller that wants LSP positions wants the index they are measured
against, and that is the shape every call site already had.

**The gutter carries no trailing space.** The reference emitted `" | "` on the frame's blank lines,
leaving trailing whitespace on two lines of every diagnostic. Here the gutter ends at `|` and
whatever follows adds its own separator.

**`#allow` arrived with RFC-026**, so the suppression mechanism §4 wanted for W2004 already existed.
It also grew a `directives` field on `TestDecl`, which had none - a `test {}` block can now carry
`#allow` like any other declaration.

## Deferred

- **Notes and related spans.** The reference rendered `Diagnostic.Notes`
  recursively. Nothing in the self-hosted compiler produces a secondary
  diagnostic today, and `Severity.Info` has no producer either. A recursive
  `notes: List(Diagnostic)` field arrives with its first caller.
- **Long-line windowing.** A span past the terminal width should scroll the line.
  `get_terminal_size()` exists; the frame does not use it yet.
- **Machine-readable output.** `--diagnostic-format=json` for editors that do not
  speak LSP.

## Open questions

1. Does the LSP want the rendered frame anywhere? Hover on an error and
   `textDocument/diagnostic` both take structured data, so the answer is
   probably no, and `flang_core.render` stays CLI-only.
2. `context_lines` is fixed at 1, matching the reference. Worth a flag, or is
   one line before and after always right?
3. A recursive `notes: List(Diagnostic)` is a self-referential struct. Does the
   checker accept one today, or does it hit E2071? Decides whether "arrives with
   its first caller" is cheap or is its own ticket.
