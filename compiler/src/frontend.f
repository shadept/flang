// frontend - the compiler's terminal-side helpers: read a source file and render diagnostics over
// `flang_core.Diagnostic`. The analysis pipeline itself is `flang_driver`; this is just the CLI's
// I/O and rendering edge.

import std.dict
import std.env
import std.io.file
import std.list
import std.option
import std.result
import std.string
import std.string_builder
import std.terminal
import flang_core.diagnostic
import flang_core.line_index
import flang_core.render

// Read a source file whole.
pub fn read_source(path: String) Result(OwnedString, FileError) {
    let file = open_file(path, FileMode.Read)?
    defer close_file(&file)
    return read_all(&file)
}

// ── diagnostic rendering (terminal) ────────────────────────────────────

// Whether escape sequences reach the destination. `auto` asks the destination: a terminal gets
// them, a redirected stream does not, and `NO_COLOR` or a dumb `TERM` opt out however the stream is
// attached.
pub type ColorChoice = enum {
    Auto
    Always
    Never
}

pub fn color_choice(name: String) ColorChoice? {
    if name == "auto" {
        return Some(ColorChoice.Auto)
    }
    if name == "always" {
        return Some(ColorChoice.Always)
    }
    if name == "never" {
        return Some(ColorChoice.Never)
    }
    return null
}

// Resolve the choice against the environment, once per run. Enables the Windows console's escape
// handling as a side effect when the answer is yes, since a console that has not been told to
// interpret them prints them literally.
pub fn resolve_style(choice: ColorChoice) RenderStyle {
    const on = choice match {
        Always => true
        Never => false
        Auto => auto_color()
    }
    if on {
        enable_ansi()
    }
    return render_style(on)
}

fn auto_color() bool {
    if env("NO_COLOR").is_some() {
        return false
    }
    const term = env("TERM")
    if term.is_some() and term.unwrap() == "dumb" {
        return false
    }
    return is_tty(STDERR_FD)
}

// Render diagnostics across a multi-module project, selecting each one's source and path by its
// span's file id. Spanless diagnostics fall back to the first source.
//
// The line index of each file is built once and reused, so a file with many diagnostics costs one
// scan rather than one per diagnostic.
pub fn render_project_diagnostics(diags: &List(Diagnostic), paths: &List(OwnedString),
    sources: &List(OwnedString), style: &RenderStyle) {
    let indexes: Dict(usize, LineIndex) = dict()
    defer indexes.deinit()

    for &d in diags {
        const fid = d.span.file_id
        let which: usize = 0
        if fid >= 0i32 and (fid as usize) < sources.len {
            which = fid as usize
        } else if sources.len == 0 {
            continue
        }
        const source = sources[which].as_view()
        if !indexes.contains(which) {
            indexes.set(which, line_index(source))
        }
        const idx = indexes.get_ref(which).unwrap()
        const text = render_diagnostic(paths[which].as_view(), source, idx, d, style)
        defer text.deinit()
        write_err(text.as_view())
    }
}

// One diagnostic, for callers holding a single source.
pub fn print_diagnostic(path: String, source: String, d: &Diagnostic, style: &RenderStyle) {
    let idx = line_index(source)
    defer idx.deinit()
    const text = render_diagnostic(path, source, &idx, d, style)
    defer text.deinit()
    write_err(text.as_view())
}

// Diagnostics go to stderr: build progress goes to stdout, and a caller redirecting one should not
// have to take the other with it.
fn write_err(text: String) {
    const _r = write(&stderr, text)
}
