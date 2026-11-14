// `vendor/<stem>.f` for each header a project lists under `[build.<os>].headers` (RFC-044).
//
// A header is preprocessed with the C compiler the build uses, through a probe file that also
// expands the library's object-like macros, and `flang_bindgen` turns the output into a module. A
// stamp beside the module records the library headers it came from and a hash of each; while every
// hash still matches, nothing is discovered, spawned or written.

import std.collections.list
import std.io.dir
import std.io.file
import std.io.fs
import std.option
import std.path
import std.result
import std.string
import std.string_builder

import flang_analysis.resolver
import flang_bindgen.bindgen
import flang_bindgen.emit
import flang_bindgen.macros
import flang_bindgen.model
import flang_codegen.backend
import flang_codegen.c_backend

const STAMP_VERSION: String = "flang-bindgen 1"

pub type BindingsReport = struct {
    warnings: List(OwnedString)
    errors: List(OwnedString)
}

pub fn deinit(self: move BindingsReport) {
    self.warnings.deinit()
    self.errors.deinit()
}

/// Bring `<vendor_dir>/<stem>.f` up to date for every header. Each message names its header.
pub fn generate_vendor(headers: &List(OwnedString), vendor_dir: String) BindingsReport {
    let report = BindingsReport { warnings = list(0), errors = list(0) }
    let absolute: List(OwnedString) = list(headers.len)
    defer absolute.deinit()
    for &h in headers {
        absolute.push(absolute_path(h.view()))
    }
    let stale: List(String) = list(0)
    defer stale.deinit()
    for &h in absolute {
        const hp = path(h.view())
        defer hp.deinit()
        const stem = hp.file_stem().unwrap_or("bindings")
        const module_path = $"{vendor_dir}/{stem}.f"
        const stamp_path = $"{vendor_dir}/{stem}.stamp"
        defer module_path.deinit()
        defer stamp_path.deinit()
        if !stamp_fresh(stamp_path.view(), module_path.view(), h.view()) {
            stale.push(h.view())
        }
    }
    if stale.len == 0 {
        return report
    }
    const found = discover_compiler()
    if found.is_err() {
        report.errors.push($"FFI: {stale[0]}: no C compiler found to read the header")
        return report
    }
    const cc = found.unwrap()
    defer cc.deinit()
    for h in stale.as_slice() {
        bind_header(&cc, h, vendor_dir, &report)
    }
    return report
}

// The probe file lives in `vendor/`, so it names the header by an absolute path.
fn absolute_path(p: String) OwnedString {
    const rel = path(p)
    defer rel.deinit()
    return to_absolute(&rel) match {
        Ok(a) => {
            const s = from_view(a.as_view())
            a.deinit()
            s
        }
        Err(_) => from_view(p)
    }
}

fn bind_header(cc: &CompilerInfo, header: String, vendor_dir: String, report: &BindingsReport) {
    const hp = path(header)
    defer hp.deinit()
    const stem = hp.file_stem().unwrap_or("bindings")
    const root = normalize_path(hp.parent().unwrap_or("."), false, false)
    defer root.deinit()
    const rp = path(root.view())
    defer rp.deinit()
    if !is_file(header) {
        report.errors.push($"FFI: {header}: no such header")
        return
    }
    const made = create_dir_all(vendor_dir)
    if made.is_err() {
        report.errors.push($"FFI: {header}: cannot create `{vendor_dir}`")
        return
    }

    const probe = library_probe(header, root.view())
    defer probe.deinit()
    const probe_path = $"{vendor_dir}/.{stem}.probe.c"
    defer probe_path.deinit()
    if !write_atomic(probe_path.view(), probe.view()) {
        report.errors.push($"FFI: {header}: cannot write `{probe_path.view()}`")
        return
    }
    let dirs: List(String) = list(2)
    defer dirs.deinit()
    dirs.push(root.view())
    rp.parent() match {
        Some(above) => dirs.push(above)
        None => {}
    }
    const pre = preprocess(cc, probe_path.view(), dirs.as_slice())
    remove_file(probe_path.view())
    if pre.is_err() {
        const why = pre.unwrap_err()
        report.errors.push($"FFI: {header}: the C preprocessor failed:\n{why.view()}")
        why.deinit()
        return
    }
    const text = pre.unwrap()
    defer text.deinit()

    const b = generate_bindings(
        text.view(),
        BindgenConfig {
            header = file_name(header).unwrap_or(header),
            root = root.view(),
            host = host_model(),
            fold_case = folds_case(),
        },
    )
    defer b.deinit()
    for &w in b.warnings {
        report.warnings.push($"FFI: {w.view()}")
    }
    const module_path = $"{vendor_dir}/{stem}.f"
    defer module_path.deinit()
    if !write_atomic(module_path.view(), b.source.view()) {
        report.errors.push($"FFI: {header}: cannot write `{module_path.view()}`")
        return
    }
    const stamp = stamp_text(header, &b.files)
    defer stamp.deinit()
    const stamp_path = $"{vendor_dir}/{stem}.stamp"
    defer stamp_path.deinit()
    write_atomic(stamp_path.view(), stamp.view())
}

// The probe file over every header under the library's directory.
fn library_probe(header: String, root: String) OwnedString {
    let texts: List(OwnedString) = list(16)
    defer texts.deinit()
    const pattern = $"{root}/**/*.h"
    defer pattern.deinit()
    const it = glob(pattern.view())
    if it.is_ok() {
        const paths = it.unwrap()
        defer paths.deinit()
        for p in paths {
            read_text(p) match {
                Some(t) => texts.push(t)
                None => {}
            }
        }
    }
    let views: List(String) = list(texts.len)
    defer views.deinit()
    for &t in texts {
        views.push(t.view())
    }
    return probe_source(header, views.as_slice())
}

fn host_model() Host {
    #if platform.os == "windows" { return Host { long_bits = 32, wchar_bits = 16 } }
    return Host { long_bits = 64, wchar_bits = 32 }
}

fn folds_case() bool {
    #if platform.os == "windows" { return true }
    return false
}

// ---- Stamp ----

// `flang-bindgen 1`, the header, then one `<hash> <path>` line per library header read.
fn stamp_text(header: String, files: &List(OwnedString)) OwnedString {
    let sb = string_builder(256)
    sb.append(STAMP_VERSION)
    sb.append("\nheader ")
    sb.append(header)
    sb.append("\n")
    for &f in files {
        const h = file_hash(f.view())
        if h.is_none() {
            continue
        }
        sb.append(h.unwrap() as u64)
        sb.append(" ")
        sb.append(f.view())
        sb.append("\n")
    }
    return sb.to_string()
}

fn stamp_fresh(stamp_path: String, module_path: String, header: String) bool {
    if !is_file(module_path) {
        return false
    }
    const text = read_text(stamp_path)
    if text.is_none() {
        return false
    }
    const s = text.unwrap()
    defer s.deinit()
    const lines = s.view().split('\n')
    defer lines.deinit()
    const header_line = $"header {header}"
    defer header_line.deinit()
    if lines.len < 2 or lines[0] != STAMP_VERSION or lines[1] != header_line.view() {
        return false
    }
    for k in 2..lines.len {
        const line = lines[k]
        if line.len == 0 {
            continue
        }
        const sp = line.find(' ')
        if sp.is_none() {
            return false
        }
        const h = file_hash(line[sp.unwrap() + 1..line.len])
        if h.is_none() {
            return false
        }
        const want = line[0..sp.unwrap()]
        const got = $"{h.unwrap() as u64}"
        defer got.deinit()
        if got.view() != want {
            return false
        }
    }
    return true
}

fn file_hash(path: String) usize? {
    return read_text(path) match {
        Some(t) => {
            const h = hash(t.view())
            t.deinit()
            Some(h)
        }
        None => null
    }
}

// Write through a temporary file and a rename, so a reader never sees half a file.
fn write_atomic(path: String, contents: String) bool {
    const tmp = $"{path}.tmp"
    defer tmp.deinit()
    const opened = open_file(tmp.view(), FileMode.Write)
    if opened.is_err() {
        return false
    }
    let f = opened.unwrap()
    const w = write(&f, contents)
    close_file(f)
    if w.is_err() {
        return false
    }
    return rename(tmp.view(), path).is_ok()
}
