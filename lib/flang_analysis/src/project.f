// flang.toml manifest model, read from a std.encoding.toml document. Parsed strings are copied into
// `OwnedString`s so a `Project` outlives the source text.

import std.allocator
import std.collections.list
import std.collections.ordered_dict
import std.encoding.toml
import std.encoding.value
import std.io.fs
import std.io.writer
import std.option
import std.result
import std.string
import std.string_builder
import std.test

pub type ProjectKind = enum {
    Exe
    Lib
}

// One `[dependencies]` entry: `name = { path = "..." }`. Path-based only.
pub type DependencySpec = struct {
    name: OwnedString
    path: OwnedString
}

pub fn deinit(self: move DependencySpec) {
    self.name.deinit()
    self.path.deinit()
}

// A `[build.<os>]` table - native toolchain inputs for one platform.
pub type PlatformConfig = struct {
    headers: List(OwnedString)
    libs: List(OwnedString)
    cflags: List(OwnedString)
    ldflags: List(OwnedString)
}

// One `[fmt]` table entry, its value as text (a string unquoted, a number or bool as written). The
// manifest model stays formatter-agnostic: flang_fmt interprets the keys.
pub type FmtEntry = struct {
    key: OwnedString
    value: OwnedString
}

pub fn deinit(self: move FmtEntry) {
    self.key.deinit()
    self.value.deinit()
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
    fmt: List(FmtEntry)
}

// Why a manifest was not read.
pub type ManifestError = enum {
    // The text is not valid TOML.
    Syntax(TomlError)
    // A known key holds the wrong kind of value. The payload names it, `section.key`.
    WrongType(String)
}

// `DuplicateKey at 3:5`, or "`project.name` has the wrong type".
pub fn format(self: ManifestError, w: Writer, spec: String) {
    self match {
        Syntax(e) => e.format(w, "")
        WrongType(field) => {
            w.write_byte('`')
            w.write_str(field)
            w.write_str("` has the wrong type")
        }
    }
}

// Public API

// Parse a flang.toml manifest. Missing `[project]` fields fall back to defaults (`kind = exe`,
// `source = "src/**/*.f"`, `output = "build"`); callers that require a field validate it
// themselves. Unknown sections and keys are ignored.
pub fn parse_project(text: String, allocator: &Allocator? = null) Result(Project, ManifestError) {
    const parsed = parse_toml(text, allocator)
    if parsed.is_err() {
        return Err(ManifestError.Syntax(parsed.unwrap_err()))
    }
    let doc = parsed.unwrap()
    defer doc.deinit()
    let proj = new_project(allocator)
    let r = ManifestReader { allocator = allocator, wrong = null }
    r.read_manifest(&proj, &doc)
    if r.wrong.is_some() {
        proj.deinit()
        return Err(ManifestError.WrongType(r.wrong.unwrap()))
    }
    return Ok(move proj)
}

pub fn deinit(self: move Project) {
    self.name.deinit()
    self.version.deinit()
    self.source.deinit()
    self.output.deinit()
    self.deps.deinit()
    const windows = move self.windows
    deinit_platform(windows)
    const linux = move self.linux
    deinit_platform(linux)
    const macos = move self.macos
    deinit_platform(macos)
    self.global_imports.deinit()
    self.fmt.deinit()
}

// The `[build.<os>]` config for the host platform.
pub fn current_platform(self: &Project) &PlatformConfig {
    #if platform.os == "windows" { return &self.windows }
    #if platform.os == "macos" { return &self.macos }
    return &self.linux
}

// Expand a source glob (e.g. `src/**/*.f`) into owned file paths, relative to the current
// directory. Returns an empty list on a glob error.
//
// `x.generated.f` files are `--emit-generated` debug output, never input: template expansion is in
// memory (RFC-021). They are skipped so a stale emission next to its origin cannot become a second
// module.
pub fn glob_sources(pattern: String, allocator: &Allocator? = null) List(OwnedString) {
    let out: List(OwnedString) = list(0, allocator)
    let r = glob(pattern, allocator)
    if r.is_err() {
        return out
    }
    let it = r.unwrap()
    defer it.deinit()
    for path in it {
        if ends_with(path, ".generated.f") {
            continue
        }
        out.push(from_view(path))
    }
    return out
}

// Construction / teardown helpers

fn new_project(alloc: &Allocator?) Project {
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
        fmt = list(0, alloc),
    }
}

fn new_platform(alloc: &Allocator?) PlatformConfig {
    return PlatformConfig {
        headers = list(0, alloc),
        libs = list(0, alloc),
        cflags = list(0, alloc),
        ldflags = list(0, alloc),
    }
}

fn deinit_platform(self: move PlatformConfig) {
    self.headers.deinit()
    self.libs.deinit()
    self.cflags.deinit()
    self.ldflags.deinit()
}

// Reading the document

// Copies the manifest's fields out of the document, keeping the first key found with the wrong
// type.
type ManifestReader = struct {
    allocator: &Allocator?
    wrong: String?
}

fn mismatch(self: &ManifestReader, field: String) {
    if self.wrong.is_none() {
        self.wrong = Some(field)
    }
}

fn read_manifest(self: &ManifestReader, proj: &Project, doc: &Value) {
    const project = self.section(doc, "project")
    if project.is_some() {
        self.read_project(proj, project.unwrap())
    }
    const deps = self.section(doc, "dependencies")
    if deps.is_some() {
        self.read_deps(proj, deps.unwrap())
    }
    const fmt = self.section(doc, "fmt")
    if fmt.is_some() {
        self.read_fmt(proj, fmt.unwrap())
    }
    const imports = self.section(doc, "imports")
    if imports.is_some() {
        self.replace_strings(&proj.global_imports, imports.unwrap(), "global", "imports.global")
    }
    const build = self.section(doc, "build")
    if build.is_some() {
        self.read_platform(&proj.windows, build.unwrap(), "windows", "build.windows")
        self.read_platform(&proj.linux, build.unwrap(), "linux", "build.linux")
        self.read_platform(&proj.macos, build.unwrap(), "macos", "build.macos")
    }
}

// The table under `key`, or null when absent or (recorded as wrong) not a table.
fn section(self: &ManifestReader, table: &Value, key: String) &Value? {
    const v = table.get(key)
    if v.is_none() {
        return null
    }
    if !v.unwrap().is_map() {
        self.mismatch(key)
        return null
    }
    return v
}

fn read_project(self: &ManifestReader, proj: &Project, t: &Value) {
    self.replace_text(&proj.name, t, "name", "project.name")
    self.replace_text(&proj.version, t, "version", "project.version")
    self.replace_text(&proj.source, t, "source", "project.source")
    self.replace_text(&proj.output, t, "output", "project.output")
    const kind = t.get("kind")
    if kind.is_none() {
        return
    }
    const s = kind.unwrap().as_string()
    if s.is_none() {
        self.mismatch("project.kind")
        return
    }
    proj.kind = if s.unwrap() == "lib" { ProjectKind.Lib } else { ProjectKind.Exe }
}

fn read_deps(self: &ManifestReader, proj: &Project, t: &Value) {
    for e in t.as_map().unwrap() {
        const path = e.value.get("path")
        const text = if path.is_some() { path.unwrap().as_string() } else { null }
        if text.is_none() {
            self.mismatch("dependencies")
            return
        }
        proj.deps.push(DependencySpec {
            name = from_view(e.key.view, self.allocator),
            path = from_view(text.unwrap(), self.allocator),
        })
    }
}

fn read_fmt(self: &ManifestReader, proj: &Project, t: &Value) {
    for e in t.as_map().unwrap() {
        const text = scalar_text(&e.value, self.allocator)
        if text.is_none() {
            self.mismatch("fmt")
            return
        }
        proj.fmt.push(
            FmtEntry { key = from_view(e.key.view, self.allocator), value = text.unwrap() },
        )
    }
}

fn read_platform(
    self: &ManifestReader,
    pc: &PlatformConfig,
    build: &Value,
    os: String,
    field: String,
) {
    const t = self.section(build, os)
    if t.is_none() {
        return
    }
    self.replace_strings(&pc.headers, t.unwrap(), "headers", field)
    self.replace_strings(&pc.libs, t.unwrap(), "libs", field)
    self.replace_strings(&pc.cflags, t.unwrap(), "cflags", field)
    self.replace_strings(&pc.ldflags, t.unwrap(), "ldflags", field)
}

// Overwrites `dest` with the string under `key`, when there is one.
fn replace_text(self: &ManifestReader, dest: &OwnedString, t: &Value, key: String, field: String) {
    const v = t.get(key)
    if v.is_none() {
        return
    }
    const s = v.unwrap().as_string()
    if s.is_none() {
        self.mismatch(field)
        return
    }
    const old = replace(dest, from_view(s.unwrap(), self.allocator))
    old.deinit()
}

// Overwrites `dest` with the array of strings under `key`, when there is one.
fn replace_strings(
    self: &ManifestReader,
    dest: &List(OwnedString),
    t: &Value,
    key: String,
    field: String,
) {
    const v = t.get(key)
    if v.is_none() {
        return
    }
    const items = v.unwrap().as_array()
    if items.is_none() {
        self.mismatch(field)
        return
    }
    let out: List(OwnedString) = list(items.unwrap().len, self.allocator)
    for i in 0..items.unwrap().len {
        const s = items.unwrap()[i].as_string()
        if s.is_none() {
            out.deinit()
            self.mismatch(field)
            return
        }
        out.push(from_view(s.unwrap(), self.allocator))
    }
    const old = replace(dest, out)
    old.deinit()
}

// A string, number or bool as the text it reads as; null for anything else.
fn scalar_text(v: &Value, allocator: &Allocator?) OwnedString? {
    let sb = string_builder(16, allocator)
    defer sb.deinit()
    v.* match {
        Str(s) => sb.append(s.view)
        Int(n) => sb.append(n)
        Float(f) => sb.append(f)
        Bool(b) => sb.append(if b { "true" } else { "false" })
        else => {
            return null
        }
    }
    return Some(sb.to_string())
}

// Tests

test "parses project metadata, deps, build config and imports" {
    let src = "# manifest\n[project]\nname = \"demo\"\nversion = \"0.2.0\"\nkind = \"lib\"\nsource = \"src/**/*.f\"\n\n[dependencies]\nflang_core = { path = \"../flang_core\" }\nflang_parser = { path = \"../lib/flang_parser\" }\n\n[build.windows]\nlibs = [\"raylib.lib\", \"user32.lib\"]\nheaders = [\"vendor/raylib.h\"]\n\n[imports]\nglobal = [\"std.prelude\"]\n"
    let p = parse_project(src).unwrap()
    defer p.deinit()

    assert_true(p.name.view == "demo", "name parsed")
    assert_true(p.version.view == "0.2.0", "version parsed")
    let is_lib = p.kind match { Lib => true, _ => false }
    assert_true(is_lib, "kind = lib")

    assert_eq(p.deps.len, 2 as usize, "two dependencies")
    assert_true(p.deps[0].name.view == "flang_core", "dep 0 name")
    assert_true(p.deps[0].path.view == "../flang_core", "dep 0 path")
    assert_true(p.deps[1].path.view == "../lib/flang_parser", "dep 1 path")

    assert_eq(p.windows.libs.len, 2 as usize, "two windows libs")
    assert_true(p.windows.libs[0].view == "raylib.lib", "lib 0")
    assert_true(p.windows.libs[1].view == "user32.lib", "lib 1")
    assert_eq(p.windows.headers.len, 1 as usize, "one windows header")

    assert_eq(p.global_imports.len, 1 as usize, "one global import")
    assert_true(p.global_imports[0].view == "std.prelude", "global import value")
}

test "collects [fmt] entries with values as text" {
    let p = parse_project(
        "[project]\nname = \"x\"\n\n[fmt]\nindent = 2\ntrailing-comma = \"always\"\nsort = true\n",
    ).unwrap()
    defer p.deinit()
    assert_eq(p.fmt.len, 3 as usize, "three fmt entries")
    assert_true(p.fmt[0].key.view == "indent", "key 0")
    assert_true(p.fmt[0].value.view == "2", "integer as text")
    assert_true(p.fmt[1].key.view == "trailing-comma", "key 1")
    assert_true(p.fmt[1].value.view == "always", "string unquoted")
    assert_true(p.fmt[2].value.view == "true", "bool as text")
}

test "applies defaults for kind, source and output" {
    let p = parse_project("[project]\nname = \"x\"\nversion = \"1.0\"\n").unwrap()
    defer p.deinit()
    let is_exe = p.kind match { Exe => true, _ => false }
    assert_true(is_exe, "kind defaults to exe")
    assert_true(p.source.view == "src/**/*.f", "source default")
    assert_true(p.output.view == "build", "output default")
    assert_eq(p.deps.len, 0 as usize, "no deps")
}

test "ignores comments and blank lines" {
    let p = parse_project(
        "\n  # a comment\n[project]\nname = \"c\"  # trailing\nversion = \"2\"\n\n",
    ).unwrap()
    defer p.deinit()
    assert_true(p.name.view == "c", "name ignores trailing comment")
    assert_true(p.version.view == "2", "version after blank lines")
}

test "invalid TOML and wrongly typed keys are errors" {
    const syntax = parse_project("[project]\nname = \"x\"\nname = \"y\"\n")
    const is_syntax = syntax match {
        Err(e) => e match { Syntax(t) => t.kind == TomlErrorKind.DuplicateKey, else => false }
        Ok(p) => {
            p.deinit()
            false
        }
    }
    assert_true(is_syntax, "duplicate key is a syntax error")

    const typed = parse_project("[project]\nname = 3\n")
    const field = typed match {
        Err(e) => e match { WrongType(f) => f, else => "" }
        Ok(p) => {
            p.deinit()
            ""
        }
    }
    assert_eq(field, "project.name", "wrong type names the key")

    const dep = parse_project("[dependencies]\nx = \"../x\"\n")
    assert_true(dep.is_err(), "a dependency must be a table with a path")
}
