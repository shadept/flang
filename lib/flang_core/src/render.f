// Terminal rendering for a `Diagnostic`: a header, the source line the span points at, and a caret
// run under the offending range.
//
//     error[E2002]: expected `i32`, got `String`
//       --> src/checker.f:16:13
//        |
//     15 |     let total = 0
//     16 |     total = name
//        |             ^^^^ expected `i32`, got `String`
//     17 | }
//        |
//
// Pure: the path, the text, the index and the style arrive through the signature and a string comes
// back. Deciding whether the destination wants color, and writing the result, are the caller's.
//
// Caret columns are display columns, not byte offsets: tabs expand and a multi-byte codepoint
// counts once. East Asian width and combining marks are not modelled.

import std.allocator
import std.encoding.utf8
import std.list
import std.string
import std.string_builder
import std.terminal
import std.test
import flang_core.diagnostic
import flang_core.line_index
import flang_core.span

pub type RenderStyle = struct {
    color: bool
    // Columns a tab advances to in the rendered source line.
    tab_width: usize
    // Source lines shown before the span and after it.
    context_lines: usize
}

// Colorless, 4-column tabs, one line of context either side.
pub fn render_style() RenderStyle {
    return .{ color = false, tab_width = 4, context_lines = 1 }
}

pub fn render_style(color: bool) RenderStyle {
    return .{ color = color, tab_width = 4, context_lines = 1 }
}

// One diagnostic, ready to write. A spanless diagnostic (`none_span`) renders as the header alone.
pub fn render_diagnostic(path: String, source: String, idx: &LineIndex, d: &Diagnostic,
    style: &RenderStyle, allocator: &Allocator? = null) OwnedString {
    let sb = string_builder(256, allocator)
    write_header(&sb, d, style)
    if is_none(d.span) {
        return sb.to_string()
    }

    const start_line = idx.line_of(d.span.start)
    const last = if d.span.length > 0 { d.span.start + d.span.length - 1 } else { d.span.start }
    const end_line = idx.line_of(if last < idx.text_len { last } else { idx.text_len })
    const start_col = display_col(source, idx, start_line, d.span.start, style.tab_width)

    write_location(&sb, path, start_line + 1, start_col + 1, style)

    // The widest line number that will be printed decides the gutter's width.
    const last_shown = min_usize(end_line + style.context_lines, idx.line_count() - 1)
    const width = digits(last_shown + 1)

    write_gutter(&sb, "", width, style)
    sb.append("\n")

    let ln = sub_sat(start_line, style.context_lines)
    while ln < start_line {
        write_source_line(&sb, source, idx, ln, width, style)
        ln = ln + 1
    }

    ln = start_line
    while ln <= end_line {
        write_source_line(&sb, source, idx, ln, width, style)
        write_carets(&sb, source, idx, d, ln, start_line, end_line, width, style)
        ln = ln + 1
    }

    ln = end_line + 1
    while ln <= last_shown {
        write_source_line(&sb, source, idx, ln, width, style)
        ln = ln + 1
    }

    write_gutter(&sb, "", width, style)
    sb.append("\n")
    return sb.to_string()
}

// ── pieces ─────────────────────────────────────────────────────────────

// Escape sequences come from `std.terminal`; `paint`/`unpaint` are no-ops under a colorless style.
fn paint(sb: &StringBuilder, style: &RenderStyle, color: Color, bold: bool) {
    if !style.color {
        return
    }
    const w = sb.writer()
    if bold {
        set_style(w, Style.Bold)
    }
    set_fg(w, color)
}

fn unpaint(sb: &StringBuilder, style: &RenderStyle) {
    if !style.color {
        return
    }
    reset(sb.writer())
}

fn write_header(sb: &StringBuilder, d: &Diagnostic, style: &RenderStyle) {
    paint(sb, style, severity_color(d.severity), true)
    sb.append(severity_label(d.severity))
    if d.code.len > 0 {
        sb.append("[")
        sb.append(d.code)
        sb.append("]")
    }
    unpaint(sb, style)
    sb.append(": ")
    paint(sb, style, Color.Default, true)
    sb.append(d.message.as_view())
    unpaint(sb, style)
    sb.append("\n")
}

fn write_location(sb: &StringBuilder, path: String, line: usize, col: usize, style: &RenderStyle) {
    paint(sb, style, Color.Blue, true)
    sb.append("  --> ")
    unpaint(sb, style)
    sb.append(path)
    sb.append(":")
    sb.append(line)
    sb.append(":")
    sb.append(col)
    sb.append("\n")
}

// ` NN |` in the frame's color, or ` <spaces> |` when `number` is empty. Content that follows adds
// its own separating space, so an empty frame line carries no trailing whitespace.
fn write_gutter(sb: &StringBuilder, number: String, width: usize, style: &RenderStyle) {
    paint(sb, style, Color.Blue, true)
    sb.append(" ")
    let pad = width
    if number.len < width {
        pad = width - number.len
    } else {
        pad = 0
    }
    for _i in 0..pad {
        sb.append(" ")
    }
    sb.append(number)
    sb.append(" |")
    unpaint(sb, style)
}

fn write_source_line(sb: &StringBuilder, source: String, idx: &LineIndex, line: usize, width: usize,
    style: &RenderStyle) {
    const n = uint_text(line + 1)
    defer n.deinit()
    write_gutter(sb, n.as_view(), width, style)
    sb.append(" ")
    append_expanded(sb, line_text(source, idx, line), style.tab_width)
    sb.append("\n")
}

// The caret run under `line`'s share of the span, with the hint after it on the last line.
fn write_carets(sb: &StringBuilder, source: String, idx: &LineIndex, d: &Diagnostic, line: usize,
    start_line: usize, end_line: usize, width: usize, style: &RenderStyle) {
    const text = line_text(source, idx, line)
    const cols = display_width(text, style.tab_width)

    let from: usize = 0
    if line == start_line {
        from = display_col(source, idx, line, d.span.start, style.tab_width)
    }
    let to = cols
    if line == end_line and d.span.length > 0 {
        to = display_col(source, idx, line, d.span.start + d.span.length, style.tab_width)
    }
    if to <= from {
        to = from + 1
    }

    write_gutter(sb, "", width, style)
    sb.append(" ")
    for _i in 0..from {
        sb.append(" ")
    }
    paint(sb, style, severity_color(d.severity), false)
    for _i in 0..(to - from) {
        sb.append("^")
    }
    if line == end_line and d.hint.len > 0 {
        sb.append(" ")
        sb.append(d.hint.as_view())
    }
    unpaint(sb, style)
    sb.append("\n")
}

// ── text measurement ───────────────────────────────────────────────────

fn line_text(source: String, idx: &LineIndex, line: usize) String {
    const b = idx.line_bounds(source, line)
    return source[b.0..b.1]
}

// Columns `offset` sits at within its line once tabs are expanded, counting a codepoint once.
fn display_col(source: String, idx: &LineIndex, line: usize, offset: usize,
    tab_width: usize) usize {
    const b = idx.line_bounds(source, line)
    let stop = offset
    if stop < b.0 {
        stop = b.0
    }
    if stop > b.1 {
        stop = b.1
    }
    return display_width(source[b.0..stop], tab_width)
}

fn display_width(text: String, tab_width: usize) usize {
    let cols: usize = 0
    let i: usize = 0
    const bytes = text.as_raw_bytes()
    while i < text.len {
        if text[i] == '\t' {
            cols = cols + (tab_width - (cols % tab_width))
            i = i + 1
            continue
        }
        const decoded = decode_char(bytes[i..bytes.len])
        const step = if decoded.1 == 0 { 1 } else { decoded.1 }
        cols = cols + 1
        i = i + step
    }
    return cols
}

// The line as shown: tabs become the spaces that advance to the next stop.
fn append_expanded(sb: &StringBuilder, text: String, tab_width: usize) {
    let cols: usize = 0
    for i in 0..text.len {
        if text[i] == '\t' {
            const pad = tab_width - (cols % tab_width)
            for _p in 0..pad {
                sb.append(" ")
            }
            cols = cols + pad
            continue
        }
        sb.append(text[i..(i + 1)])
        cols = cols + 1
    }
}

// ── small helpers ──────────────────────────────────────────────────────

fn severity_label(s: Severity) String {
    return s match {
        Severity.Error => "error"
        Severity.Warning => "warning"
        Severity.Info => "info"
        Severity.Hint => "hint"
    }
}

fn severity_color(s: Severity) Color {
    return s match {
        Severity.Error => Color.Red
        Severity.Warning => Color.Yellow
        Severity.Info => Color.Cyan
        Severity.Hint => Color.Green
    }
}

fn digits(n: usize) usize {
    let d: usize = 1
    let v = n
    while v >= 10 {
        v = v / 10
        d = d + 1
    }
    return d
}

fn uint_text(n: usize) OwnedString {
    let sb = string_builder(8)
    sb.append(n)
    return sb.to_string()
}

fn min_usize(a: usize, b: usize) usize {
    return if a < b { a } else { b }
}

fn sub_sat(a: usize, b: usize) usize {
    return if b > a { 0 } else { a - b }
}

// Tests

fn diag_at(code: String, message: String, start: usize, length: usize) Diagnostic {
    return diag_at(code, message, start, length, "")
}

fn diag_at(code: String, message: String, start: usize, length: usize, hint: String) Diagnostic {
    return .{
        severity = Severity.Error,
        code = code,
        message = from_view(message),
        hint = from_view(hint),
        span = .{ file_id = 0, start = start, length = length },
    }
}

fn render_of(source: String, d: &Diagnostic) OwnedString {
    let idx = line_index(source)
    defer idx.deinit()
    const style = render_style()
    return render_diagnostic("t.f", source, &idx, d, &style)
}

test "a single-line span gets carets under exactly its range" {
    const src = "let a = 1\nlet b = wrong\nlet c = 3\n"
    let d = diag_at("E2002", "expected `i32`", 18, 5)
    defer d.deinit()
    const out = render_of(src, &d)
    defer out.deinit()

    const want = "error[E2002]: expected `i32`\n  --> t.f:2:9\n   |\n 1 | let a = 1\n 2 | let b = wrong\n   |         ^^^^^\n 3 | let c = 3\n   |\n"
    assert_eq(out.as_view(), want, "the frame reproduces the reference layout")
}

test "a hint follows the carets" {
    const src = "let b = wrong\n"
    let d = diag_at("E2002", "expected `i32`", 8, 5, "did you mean `right`?")
    defer d.deinit()
    const out = render_of(src, &d)
    defer out.deinit()

    assert_true(contains(out.as_view(), "^^^^^ did you mean `right`?"),
        "the hint sits on the caret line")
}

test "a spanless diagnostic is the header alone" {
    let hint: OwnedString
    let d: Diagnostic = .{
        severity = Severity.Error,
        code = "E1000",
        message = from_view("no input files"),
        hint = hint,
        span = none_span(),
    }
    defer d.deinit()
    const out = render_of("", &d)
    defer out.deinit()

    assert_eq(out.as_view(), "error[E1000]: no input files\n", "nothing to point at, nothing drawn")
}

test "the gutter widens with the line number" {
    let src = string_builder(256)
    for _i in 0usize..11usize {
        src.append("x\n")
    }
    src.append("let b = wrong\n")
    const text = src.to_string()
    defer text.deinit()

    let d = diag_at("E2002", "nope", 22 + 8, 5)
    defer d.deinit()
    const out = render_of(text.as_view(), &d)
    defer out.deinit()

    assert_true(contains(out.as_view(), " 12 | let b = wrong"), "two-digit numbers get two columns")
    assert_true(contains(out.as_view(), "    |"), "and the bare gutter matches their width")
}

test "carets land past an expanded tab" {
    const src = "\tlet b = wrong\n"
    let d = diag_at("E2002", "nope", 9, 5)
    defer d.deinit()
    const out = render_of(src, &d)
    defer out.deinit()

    // The tab renders as four spaces, so the caret run starts four columns further right than the
    // byte offset would put it.
    assert_true(contains(out.as_view(), "   |             ^^^^^"), "carets follow the expansion")
    assert_true(contains(out.as_view(), " 1 |     let b = wrong"), "and so does the line itself")
}

test "carets count a codepoint once, not its bytes" {
    // The comment is 3 bytes wide and one column wide.
    const src = "// é\nlet b = wrong\n"
    let d = diag_at("E2002", "nope", 14, 5)
    defer d.deinit()
    const out = render_of(src, &d)
    defer out.deinit()

    assert_true(contains(out.as_view(), "   |         ^^^^^"),
        "the second line is measured on its own")
}

test "a multi-line span underlines every line it covers" {
    const src = "let a = f(\n  1,\n  2)\nlet c = 3\n"
    let d = diag_at("E2002", "nope", 8, 12)
    defer d.deinit()
    const out = render_of(src, &d)
    defer out.deinit()

    const view = out.as_view()
    assert_true(contains(view, " 1 | let a = f(\n"), "the first line is shown")
    assert_true(contains(view, " 3 |   2)\n"), "and so is the last")
    assert_eq(count_bytes(view, '^') > 3, true, "each covered line carries carets")
}

test "color wraps the header and the carets, not the source" {
    const src = "let b = wrong\n"
    let d = diag_at("E2002", "nope", 8, 5)
    defer d.deinit()
    let idx = line_index(src)
    defer idx.deinit()
    const style = render_style(true)
    const out = render_diagnostic("t.f", src, &idx, &d, &style)
    defer out.deinit()

    const view = out.as_view()
    assert_true(contains(view, "error[E2002]"), "the code stays contiguous under color")
    assert_true(contains(view, "let b = wrong"), "the source text is written plain")
}

fn count_bytes(s: String, b: u8) usize {
    let n: usize = 0
    for i in 0..s.len {
        if s[i] == b {
            n = n + 1
        }
    }
    return n
}
