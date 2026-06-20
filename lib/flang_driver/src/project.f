// flang.toml manifest model and parser - a small TOML *subset*, only what
// manifests contain:
//   [section] / [dotted.section]
//   key = "string"  |  key = ["string", ...]  |  key = { path = "string" }
// Parsed strings are copied into `OwnedString`s so a `Project` outlives
// the source text.

import std.allocator
import std.list
import std.option
import std.result
import std.string
import std.test
import std.io.fs

pub type ProjectKind = enum {
    Exe
    Lib
}

// One `[dependencies]` entry: `name = { path = "..." }`. Path-based only.
pub type DependencySpec = struct {
    name: OwnedString
    path: OwnedString
}

// A `[build.<os>]` table - native toolchain inputs for one platform.
pub type PlatformConfig = struct {
    headers: List(OwnedString)
    libs: List(OwnedString)
    cflags: List(OwnedString)
    ldflags: List(OwnedString)
}

// A parsed manifest. Owns every string; call `deinit()` when done.
pub type Project = struct {
    name: OwnedString
    version: OwnedString
    kind: ProjectKind
    source: OwnedString
    output: OwnedString
    deps: List(DependencySpec)
    windows: PlatformConfig
    linux: PlatformConfig
    macos: PlatformConfig
    global_imports: List(OwnedString)
}

// Public API

// Parse a flang.toml manifest. Missing `[project]` fields fall back to
// defaults (`kind = exe`, `source = "src/**/*.f"`, `output = "build"`);
// callers that require a field validate it themselves.
pub fn parse_project(text: String, allocator: &Allocator? = null) Project {
    let alloc = allocator.or_global()
    let proj = new_project(alloc)
    let section: String = ""
    let pos: usize = 0
    while pos < text.len {
        let nl = next_line(text, pos)
        pos = nl.1
        let line = trim(strip_comment(nl.0))
        if line.len == 0 { continue }
        if line[0] == '[' {
            section = section_name(line)
            continue
        }
        let kv = split_kv(line)
        if kv.2 {
            apply_kv(&proj, section, kv.0, kv.1, alloc)
        }
    }
    return proj
}

pub fn deinit(self: &Project) {
    self.name.deinit()
    self.version.deinit()
    self.source.deinit()
    self.output.deinit()
    for i in 0..self.deps.len {
        let d = &self.deps[i]
        d.name.deinit()
        d.path.deinit()
    }
    self.deps.deinit()
    deinit_platform(&self.windows)
    deinit_platform(&self.linux)
    deinit_platform(&self.macos)
    deinit_strings(&self.global_imports)
    self.global_imports.deinit()
}

// The `[build.<os>]` config for the host platform.
pub fn current_platform(self: &Project) &PlatformConfig {
    #if(platform.os == "windows") { return &self.windows }
    #if(platform.os == "macos") { return &self.macos }
    return &self.linux
}

// Expand a source glob (e.g. `src/**/*.f`) into owned file paths, relative
// to the current directory. Returns an empty list on a glob error.
pub fn glob_sources(pattern: String, allocator: &Allocator? = null) List(OwnedString) {
    let alloc = allocator.or_global()
    let out: List(OwnedString) = list(0, alloc)
    let r = glob(pattern, alloc)
    if r.is_err() { return out }
    let it = r.unwrap()
    defer it.deinit()
    for path in it {
        out.push(from_view(path))
    }
    return out
}

pub fn deinit_source_list(self: &List(OwnedString)) {
    deinit_strings(self)
    self.deinit()
}

// Construction / teardown helpers

fn new_project(alloc: &Allocator) Project {
    return Project {
        name = from_view(""),
        version = from_view(""),
        kind = ProjectKind.Exe,
        source = from_view("src/**/*.f"),
        output = from_view("build"),
        deps = list(0, alloc),
        windows = new_platform(alloc),
        linux = new_platform(alloc),
        macos = new_platform(alloc),
        global_imports = list(0, alloc),
    }
}

fn new_platform(alloc: &Allocator) PlatformConfig {
    return PlatformConfig {
        headers = list(0, alloc),
        libs = list(0, alloc),
        cflags = list(0, alloc),
        ldflags = list(0, alloc),
    }
}

fn deinit_platform(self: &PlatformConfig) {
    deinit_strings(&self.headers)
    deinit_strings(&self.libs)
    deinit_strings(&self.cflags)
    deinit_strings(&self.ldflags)
    self.headers.deinit()
    self.libs.deinit()
    self.cflags.deinit()
    self.ldflags.deinit()
}

fn deinit_strings(list: &List(OwnedString)) {
    for i in 0..list.len {
        let s = &list[i]
        s.deinit()
    }
}

// Dispatch

fn apply_kv(proj: &Project, section: String, key: String, val: String, alloc: &Allocator) {
    if section == "project" {
        set_project_field(proj, key, val)
        return
    }
    if section == "dependencies" {
        let deps = &proj.deps
        deps.push(DependencySpec {
            name = from_view(key),
            path = from_view(parse_inline_path(val)),
        })
        return
    }
    if section == "imports" {
        if key == "global" {
            proj.global_imports = parse_array(val, alloc)
        }
        return
    }
    if starts_with(section, "build.") {
        let os = section[6..section.len]
        if os == "windows" { set_platform_field(&proj.windows, key, val, alloc) }
        if os == "linux" { set_platform_field(&proj.linux, key, val, alloc) }
        if os == "macos" { set_platform_field(&proj.macos, key, val, alloc) }
    }
}

fn set_project_field(proj: &Project, key: String, val: String) {
    if key == "name" { proj.name = from_view(unquote(val)) }
    if key == "version" { proj.version = from_view(unquote(val)) }
    if key == "kind" { proj.kind = parse_kind(unquote(val)) }
    if key == "source" { proj.source = from_view(unquote(val)) }
    if key == "output" { proj.output = from_view(unquote(val)) }
}

fn set_platform_field(pc: &PlatformConfig, key: String, val: String, alloc: &Allocator) {
    if key == "headers" { pc.headers = parse_array(val, alloc) }
    if key == "libs" { pc.libs = parse_array(val, alloc) }
    if key == "cflags" { pc.cflags = parse_array(val, alloc) }
    if key == "ldflags" { pc.ldflags = parse_array(val, alloc) }
}

fn parse_kind(s: String) ProjectKind {
    if s == "lib" { return ProjectKind.Lib }
    return ProjectKind.Exe
}

// Lexical helpers - index-based scans, no reliance on `and` short-circuit

// The next physical line starting at `pos` (excluding the newline) plus
// the offset just past it.
fn next_line(text: String, pos: usize) (String, usize) {
    let i = pos
    while i < text.len {
        if text[i] == '\n' { break }
        i = i + 1
    }
    return (text[pos..i], i + 1)
}

// Drop a `#` comment that isn't inside a quoted string.
fn strip_comment(line: String) String {
    let in_str = false
    let i: usize = 0
    while i < line.len {
        let c = line[i]
        if c == '"' { in_str = !in_str }
        if c == '#' {
            if !in_str { return line[0..i] }
        }
        i = i + 1
    }
    return line
}

// `[name]` / `[a.b]` -> the inner dotted name.
fn section_name(line: String) String {
    let t = trim(line)
    let a: usize = 0
    let b: usize = t.len
    if b > a {
        if t[a] == '[' { a = a + 1 }
    }
    if b > a {
        if t[b - 1] == ']' { b = b - 1 }
    }
    return trim(t[a..b])
}

// Split `key = value` at the first `=`. Third tuple element is false when
// the line has no `=`.
fn split_kv(line: String) (String, String, bool) {
    let i: usize = 0
    while i < line.len {
        if line[i] == '=' { break }
        i = i + 1
    }
    if i >= line.len {
        return ("", "", false)
    }
    return (trim(line[0..i]), trim(line[(i + 1)..line.len]), true)
}

// `{ path = "..." }` -> the first quoted string (the dependency path).
fn parse_inline_path(val: String) String {
    let i: usize = 0
    while i < val.len {
        if val[i] == '"' { break }
        i = i + 1
    }
    if i >= val.len { return "" }
    let start = i + 1
    let j = start
    while j < val.len {
        if val[j] == '"' { break }
        j = j + 1
    }
    return val[start..j]
}

// `["a", "b"]` -> owned copies of each element.
fn parse_array(val: String, alloc: &Allocator) List(OwnedString) {
    let out: List(OwnedString) = list(0, alloc)
    let inner = strip_brackets(trim(val))
    let start: usize = 0
    let i: usize = 0
    while i < inner.len {
        if inner[i] == ',' {
            push_element(&out, inner[start..i])
            start = i + 1
        }
        i = i + 1
    }
    push_element(&out, inner[start..inner.len])
    return out
}

fn push_element(out: &List(OwnedString), raw: String) {
    let piece = trim(raw)
    if piece.len > 0 {
        out.push(from_view(unquote(piece)))
    }
}

fn strip_brackets(s: String) String {
    let a: usize = 0
    let b: usize = s.len
    if b > a {
        if s[a] == '[' { a = a + 1 }
    }
    if b > a {
        if s[b - 1] == ']' { b = b - 1 }
    }
    return s[a..b]
}

fn unquote(s: String) String {
    let t = trim(s)
    if t.len >= 2 {
        if t[0] == '"' {
            if t[t.len - 1] == '"' {
                return t[1..(t.len - 1)]
            }
        }
    }
    return t
}


// Tests

test "parses project metadata, deps, build config and imports" {
    let src = "# manifest\n[project]\nname = \"demo\"\nversion = \"0.2.0\"\nkind = \"lib\"\nsource = \"src/**/*.f\"\n\n[dependencies]\nflang_core = { path = \"../flang_core\" }\nflang_parser = { path = \"../lib/flang_parser\" }\n\n[build.windows]\nlibs = [\"raylib.lib\", \"user32.lib\"]\nheaders = [\"vendor/raylib.h\"]\n\n[imports]\nglobal = [\"std.prelude\"]\n"
    let p = parse_project(src)
    defer p.deinit()

    assert_true(p.name.as_view() == "demo", "name parsed")
    assert_true(p.version.as_view() == "0.2.0", "version parsed")
    let is_lib = p.kind match { Lib => true, _ => false }
    assert_true(is_lib, "kind = lib")

    assert_eq(p.deps.len, 2 as usize, "two dependencies")
    assert_true(p.deps[0].name.as_view() == "flang_core", "dep 0 name")
    assert_true(p.deps[0].path.as_view() == "../flang_core", "dep 0 path")
    assert_true(p.deps[1].path.as_view() == "../lib/flang_parser", "dep 1 path")

    assert_eq(p.windows.libs.len, 2 as usize, "two windows libs")
    assert_true(p.windows.libs[0].as_view() == "raylib.lib", "lib 0")
    assert_true(p.windows.libs[1].as_view() == "user32.lib", "lib 1")
    assert_eq(p.windows.headers.len, 1 as usize, "one windows header")

    assert_eq(p.global_imports.len, 1 as usize, "one global import")
    assert_true(p.global_imports[0].as_view() == "std.prelude", "global import value")
}

test "applies defaults for kind, source and output" {
    let p = parse_project("[project]\nname = \"x\"\nversion = \"1.0\"\n")
    defer p.deinit()
    let is_exe = p.kind match { Exe => true, _ => false }
    assert_true(is_exe, "kind defaults to exe")
    assert_true(p.source.as_view() == "src/**/*.f", "source default")
    assert_true(p.output.as_view() == "build", "output default")
    assert_eq(p.deps.len, 0 as usize, "no deps")
}

test "ignores comments and blank lines" {
    let p = parse_project("\n  # a comment\n[project]\nname = \"c\"  # trailing\nversion = \"2\"\n\n")
    defer p.deinit()
    assert_true(p.name.as_view() == "c", "name ignores trailing comment")
    assert_true(p.version.as_view() == "2", "version after blank lines")
}
