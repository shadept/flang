// frontend — bootstrap's terminal-side helpers: read a source file and
// render diagnostics over `flang_core.Diagnostic`. The analysis pipeline
// itself is `flang_driver`; this is just the CLI's I/O and rendering edge.

import std.io.file
import std.list
import std.option
import std.result
import std.string
import std.string_builder
import flang_core.diagnostic

pub fn read_source(path: String) OwnedString? {
    const open_result = open_file(path, FileMode.Read)
    if open_result.is_err() {
        const msg = $"flang: cannot open `{path}`"
        defer msg.deinit()
        println(msg.as_view())
        return null
    }
    let file = open_result.unwrap()
    const read_result = read_all(&file)
    close_file(&file)
    if read_result.is_err() {
        const msg = $"flang: read failed `{path}`"
        defer msg.deinit()
        println(msg.as_view())
        return null
    }
    return read_result.unwrap()
}

// ── diagnostic rendering (terminal) ────────────────────────────────────

pub fn render_diagnostics(diags: &List(Diagnostic), path: String, source: String) {
    for i in 0..diags.len {
        print_diagnostic(path, source, &diags[i])
    }
}

// Render diagnostics across a multi-module project, selecting each one's
// source and path by its span's file id. Spanless diagnostics fall back to
// the first source.
pub fn render_project_diagnostics(diags: &List(Diagnostic), paths: &List(OwnedString), sources: &List(OwnedString)) {
    for i in 0..diags.len {
        let d = &diags[i]
        let fid = d.span.file_id
        if fid >= 0i32 and (fid as usize) < sources.len {
            print_diagnostic(paths[fid as usize].as_view(), sources[fid as usize].as_view(), d)
        } else {
            if sources.len > 0 {
                print_diagnostic(paths[0].as_view(), sources[0].as_view(), d)
            }
        }
    }
}

pub fn print_diagnostic(path: String, source: String, d: &Diagnostic) {
    const lc = line_col(source, d.span.start)
    const ln = lc.0
    const cn = lc.1
    const line = $"{path}:{ln}:{cn}: {severity_label(d.severity)}[{d.code}]: {d.message.as_view()}"
    defer line.deinit()
    println(line.as_view())
    if d.hint.as_view().len > 0 {
        const h = $"  hint: {d.hint.as_view()}"
        defer h.deinit()
        println(h.as_view())
    }
}

fn severity_label(s: Severity) String {
    return s match {
        Severity.Error => "error",
        Severity.Warning => "warning",
        Severity.Info => "info",
        Severity.Hint => "hint",
    }
}

// 1-based line/column for a byte offset, derived by scanning the source.
fn line_col(source: String, offset: usize) (usize, usize) {
    let line: usize = 1
    let col: usize = 1
    for i in 0..offset {
        if i >= source.len { break }
        if source[i] == '\n' { line = line + 1; col = 1 }
        else { col = col + 1 }
    }
    return (line, col)
}
