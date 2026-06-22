// Import resolution: the two symmetric halves of the C# compiler's module
// machinery, ported for the self-host driver.
//
//   - `resolve_import` maps a dotted import (`flang_parser.lexer`) to an
//     existing source file, trying project-name, dependency-name and
//     include-path rules in that order (mirrors
//     `Compilation.TryResolveImportPath`).
//   - `module_fqn` is the inverse: a source file path becomes the dotted
//     module name its symbols register under, so the import side and the
//     symbol side agree (mirrors `TemplateExpander.DeriveModulePath`).
//
// Resolution is flat and path-only: no transitive deps, no lockfile. Paths
// are normalised to forward slashes before any prefix comparison.

import std.allocator
import std.list
import std.option
import std.result
import std.string
import std.string_builder
import std.io.fs
import std.io.file
import std.test
import flang_driver.project

// One direct dependency: its `[project].name` (its import namespace) and
// its resolved source root.
pub type DepRoot = struct {
    name: OwnedString
    root: OwnedString
}

// Everything import resolution needs about the project under build. All
// roots are stored normalised (forward slashes, no trailing separator).
pub type ResolveCtx = struct {
    project_name: OwnedString
    project_source_root: OwnedString
    deps: List(DepRoot)
    stdlib_root: OwnedString
    cwd: OwnedString
}

pub fn deinit(self: &ResolveCtx) {
    self.project_name.deinit()
    self.project_source_root.deinit()
    for i in 0..self.deps.len {
        let d = &self.deps[i]
        d.name.deinit()
        d.root.deinit()
    }
    self.deps.deinit()
    self.stdlib_root.deinit()
    self.cwd.deinit()
}

// Resolve a dotted import to an existing file path, or null when no rule
// matches an existing file. The returned string is owned by the caller.
pub fn resolve_import(ctx: &ResolveCtx, segs: &List(String), allocator: &Allocator? = null) OwnedString? {
    let alloc = allocator.or_global()

    // Project rule: first segment is the project name.
    if segs.len > 1 and segs[0] == ctx.project_name.as_view() {
        let p = join_module_path(ctx.project_source_root.as_view(), segs, 1, alloc)
        if exists(p.as_view()) { return Some(p) }
        p.deinit()
    }

    // Dependency rule: first segment names a direct dependency.
    if segs.len > 1 {
        for i in 0..ctx.deps.len {
            let d = &ctx.deps[i]
            if segs[0] == d.name.as_view() {
                let p = join_module_path(d.root.as_view(), segs, 1, alloc)
                if exists(p.as_view()) { return Some(p) }
                p.deinit()
            }
        }
    }

    // Include rule: stdlib first, then the working directory.
    let p1 = join_module_path(ctx.stdlib_root.as_view(), segs, 0, alloc)
    if exists(p1.as_view()) { return Some(p1) }
    p1.deinit()

    let p2 = join_module_path(ctx.cwd.as_view(), segs, 0, alloc)
    if exists(p2.as_view()) { return Some(p2) }
    p2.deinit()

    return null
}

// The template-expansion sidecar of a source file: `foo.f` -> `foo.generated.f`
// when that file exists on disk. Null when `file_path` is itself a generated
// file, isn't a `.f` source, or has no sidecar. The bootstrap loads the
// sidecar as an extra source of the same module, standing in for the template
// expansion the C# compiler runs in memory (`#interface`, `#derive`, ...).
pub fn generated_sidecar(file_path: String, allocator: &Allocator? = null) OwnedString? {
    let alloc = allocator.or_global()
    if ends_with(file_path, ".generated.f") { return null }
    if !ends_with(file_path, ".f") { return null }
    let sb = string_builder(0, alloc)
    sb.append(file_path[0..(file_path.len - 2)])
    sb.append(".generated.f")
    let cand = sb.to_string()
    sb.deinit()
    if exists(cand.as_view()) { return Some(cand) }
    cand.deinit()
    return null
}

// Derive the dotted module name a source file's symbols register under.
// Classifies the path under project / dependency / stdlib roots in the
// same order `resolve_import` tries them; an unclassified path falls back
// to its bare file stem.
pub fn module_fqn(ctx: &ResolveCtx, path: String, allocator: &Allocator? = null) OwnedString {
    let alloc = allocator.or_global()
    let norm = normalize_sep(path, alloc)
    defer norm.deinit()
    let np = norm.as_view()

    let pr = strip_root(np, ctx.project_source_root.as_view())
    if pr.is_some() {
        return dotted_with_prefix(ctx.project_name.as_view(), pr.unwrap(), alloc)
    }

    for i in 0..ctx.deps.len {
        let dr = strip_root(np, ctx.deps[i].root.as_view())
        if dr.is_some() {
            return dotted_with_prefix(ctx.deps[i].name.as_view(), dr.unwrap(), alloc)
        }
    }

    let sr = strip_root(np, ctx.stdlib_root.as_view())
    if sr.is_some() {
        return dotted(sr.unwrap(), alloc)
    }

    let cr = strip_root(np, ctx.cwd.as_view())
    if cr.is_some() {
        return dotted(cr.unwrap(), alloc)
    }
    return dotted(basename(np), alloc)
}

// `base/seg.../tail.f` from import segments, joining with forward slashes.
pub fn join_module_path(base: String, segs: &List(String), start: usize, allocator: &Allocator? = null) OwnedString {
    let alloc = allocator.or_global()
    let sb = string_builder(0, alloc)
    sb.append(base)
    for i in start..segs.len {
        sb.append('/')
        sb.append(segs[i])
    }
    sb.append(".f")
    let out = sb.to_string()
    sb.deinit()
    return out
}

// Build a resolution context for `proj` under the current directory.
// `stdlib_root` is the include root for `std.*` / `core.*` (the value of
// the build's `--stdlib-path`). Each dependency's source root is derived
// from its own manifest, exactly as the C# compiler does.
pub fn resolve_ctx(proj: &Project, stdlib_root: String, allocator: &Allocator? = null) ResolveCtx {
    let alloc = allocator.or_global()
    let deps: List(DepRoot) = list(0, alloc)
    for i in 0..proj.deps.len {
        let d = &proj.deps[i]
        let root = normalized_owned(dep_source_root(d.path.as_view(), alloc), alloc)
        deps.push(DepRoot { name = from_view(d.name.as_view()), root = root })
    }
    return ResolveCtx {
        project_name = from_view(proj.name.as_view()),
        project_source_root = normalized_owned(source_root(".", proj.source.as_view(), alloc), alloc),
        deps = deps,
        stdlib_root = normalize_sep(stdlib_root, alloc),
        cwd = from_view("."),
    }
}

// A dependency's source root: read its manifest and take the static
// prefix of its `source` glob; fall back to `<dep>/src` when unreadable.
fn dep_source_root(dep_dir: String, alloc: &Allocator) OwnedString {
    let manifest = $"{dep_dir}/flang.toml"
    defer manifest.deinit()
    let text = read_text(manifest.as_view())
    if text.is_none() {
        return source_root(dep_dir, "src/**/*.f", alloc)
    }
    let t = text.unwrap()
    defer t.deinit()
    let dp = parse_project(t.as_view(), alloc)
    defer dp.deinit()
    return source_root(dep_dir, dp.source.as_view(), alloc)
}

// The static (glob-free) prefix of `source_glob` under `project_dir`.
// `.` as the directory means "relative to here", so it is not prefixed;
// a glob with no static prefix resolves to the directory itself.
fn source_root(project_dir: String, source_glob: String, alloc: &Allocator) OwnedString {
    let segs = split(source_glob, '/')
    defer segs.deinit()
    let sb = string_builder(0, alloc)
    let wrote = false
    if project_dir != "." and project_dir.len > 0 {
        sb.append(project_dir)
        wrote = true
    }
    for i in 0..segs.len {
        let s = segs[i]
        if contains(s, "*") { break }
        if contains(s, "?") { break }
        if wrote { sb.append('/') }
        sb.append(s)
        wrote = true
    }
    let out = sb.to_string()
    sb.deinit()
    if !wrote {
        out.deinit()
        return from_view(".")
    }
    return out
}

// Read a whole file as text, or null when it cannot be opened or read.
pub fn read_text(path: String) OwnedString? {
    let r = open_file(path, FileMode.Read)
    if r.is_err() { return null }
    let f = r.unwrap()
    let rd = read_all(&f)
    close_file(&f)
    if rd.is_err() { return null }
    return Some(rd.unwrap())
}

// Internal helpers

fn normalize_sep(path: String, alloc: &Allocator) OwnedString {
    let sb = string_builder(0, alloc)
    sb.append_replaced(path, "\\", "/")
    let out = sb.to_string()
    sb.deinit()
    return out
}

// Normalise an owned path to forward slashes, freeing the input. Keeps the
// `ResolveCtx` roots in the single separator convention `strip_root` compares
// against, so an absolute or backslashed root (e.g. an argv[0]-derived stdlib
// path on Windows) classifies the same as a forward-slash one.
fn normalized_owned(s: OwnedString, alloc: &Allocator) OwnedString {
    let n = normalize_sep(s.as_view(), alloc)
    s.deinit()
    return n
}

// The part of `path` beneath `root`, or null when `path` is not strictly
// inside `root`. A separator boundary is required so `src` never matches
// `src2/x.f`.
fn strip_root(path: String, root: String) String? {
    if root.len == 0 { return null }
    if !starts_with(path, root) { return null }
    if path.len <= root.len { return null }
    if path[root.len] != '/' { return null }
    return Some(path[(root.len + 1)..path.len])
}

// Last path component of `path` with its source extension dropped.
fn basename(path: String) String {
    let start: usize = 0
    let i: usize = 0
    while i < path.len {
        if path[i] == '/' { start = i + 1 }
        i = i + 1
    }
    return strip_source_ext(path[start..path.len])
}

// A source file's module stem: a trailing `.generated.f` (a template
// expansion) or plain `.f` removed. The bootstrap treats `x.generated.f`
// as another source of module `x`, mirroring how the C# compiler registers
// generated content under its origin module path.
fn strip_source_ext(name: String) String {
    if ends_with(name, ".generated.f") { return name[0..(name.len - 12)] }
    if ends_with(name, ".f") { return name[0..(name.len - 2)] }
    return name
}

fn dotted(rel: String, alloc: &Allocator) OwnedString {
    let sb = string_builder(0, alloc)
    append_dotted(&sb, rel)
    let out = sb.to_string()
    sb.deinit()
    return out
}

fn dotted_with_prefix(prefix: String, rel: String, alloc: &Allocator) OwnedString {
    let sb = string_builder(0, alloc)
    sb.append(prefix)
    sb.append('.')
    append_dotted(&sb, rel)
    let out = sb.to_string()
    sb.deinit()
    return out
}

// Append `rel` with `/` rewritten to `.` and the source extension dropped.
fn append_dotted(sb: &StringBuilder, rel: String) {
    let body = strip_source_ext(rel)
    let i: usize = 0
    while i < body.len {
        let c = body[i]
        if c == '/' {
            sb.append('.')
        } else {
            sb.append_byte(c)
        }
        i = i + 1
    }
}

// Tests

fn fixture_ctx() ResolveCtx {
    let deps: List(DepRoot) = list(0)
    deps.push(DepRoot {
        name = from_view("flang_parser"),
        root = from_view("lib/flang_parser/src"),
    })
    return ResolveCtx {
        project_name = from_view("flang_driver"),
        project_source_root = from_view("lib/flang_driver/src"),
        deps = deps,
        stdlib_root = from_view("stdlib"),
        cwd = from_view("."),
    }
}

test "module_fqn: project file -> project-prefixed name" {
    let ctx = fixture_ctx()
    defer ctx.deinit()
    let f = module_fqn(&ctx, "lib/flang_driver/src/driver.f")
    defer f.deinit()
    assert_true(f.as_view() == "flang_driver.driver", "project root file")
}

test "module_fqn: nested project file dots the subpath" {
    let ctx = fixture_ctx()
    defer ctx.deinit()
    let f = module_fqn(&ctx, "lib/flang_driver/src/sub/thing.f")
    defer f.deinit()
    assert_true(f.as_view() == "flang_driver.sub.thing", "nested project file")
}

test "module_fqn: dependency file -> dep-prefixed name" {
    let ctx = fixture_ctx()
    defer ctx.deinit()
    let f = module_fqn(&ctx, "lib/flang_parser/src/lexer.f")
    defer f.deinit()
    assert_true(f.as_view() == "flang_parser.lexer", "dep file")
}

test "module_fqn: stdlib file has no prefix" {
    let ctx = fixture_ctx()
    defer ctx.deinit()
    let f = module_fqn(&ctx, "stdlib/std/io/file.f")
    defer f.deinit()
    assert_true(f.as_view() == "std.io.file", "stdlib file")
}

test "module_fqn: backslash paths normalise" {
    let ctx = fixture_ctx()
    defer ctx.deinit()
    let f = module_fqn(&ctx, "stdlib\\core\\option.f")
    defer f.deinit()
    assert_true(f.as_view() == "core.option", "windows separators")
}

test "module_fqn: unclassified path falls back to file stem" {
    let ctx = fixture_ctx()
    defer ctx.deinit()
    let f = module_fqn(&ctx, "scratch/area/foo.f")
    defer f.deinit()
    assert_true(f.as_view() == "foo", "fallback stem")
}

test "join_module_path: builds base/seg/seg.f from segments" {
    let segs: List(String) = list(0)
    segs.push("std")
    segs.push("io")
    segs.push("file")
    defer segs.deinit()
    let p = join_module_path("stdlib", &segs, 0)
    defer p.deinit()
    assert_true(p.as_view() == "stdlib/std/io/file.f", "include-rule path")

    let p2 = join_module_path("dep/src", &segs, 1)
    defer p2.deinit()
    assert_true(p2.as_view() == "dep/src/io/file.f", "skips leading segment")
}

test "module_fqn: generated stdlib file registers under its origin module" {
    let ctx = fixture_ctx()
    defer ctx.deinit()
    let f = module_fqn(&ctx, "stdlib/std/io/reader.generated.f")
    defer f.deinit()
    assert_true(f.as_view() == "std.io.reader", "strips .generated.f")
}

test "module_fqn: generated dependency file keeps its dep prefix" {
    let ctx = fixture_ctx()
    defer ctx.deinit()
    let f = module_fqn(&ctx, "lib/flang_parser/src/token.generated.f")
    defer f.deinit()
    assert_true(f.as_view() == "flang_parser.token", "dep-prefixed, .generated.f stripped")
}

test "generated_sidecar: a generated file has no sidecar of its own" {
    let s = generated_sidecar("stdlib/std/io/reader.generated.f")
    assert_true(s.is_none(), "no sidecar-of-sidecar")
}

test "generated_sidecar: a non-source path has no sidecar" {
    let s = generated_sidecar("stdlib/std/io/reader.txt")
    assert_true(s.is_none(), "only .f sources have sidecars")
}

test "resolve_ctx normalises a backslash stdlib root" {
    // An absolute argv[0]-derived path on Windows arrives with `\` separators;
    // roots must be stored forward-slashed so strip_root classifies stdlib
    // files instead of falling back to their bare stem.
    let proj = parse_project("[project]\nname = \"p\"\nkind = \"exe\"\nsource = \"src/**/*.f\"\n")
    defer proj.deinit()
    let ctx = resolve_ctx(&proj, "C:\\x\\build\\stdlib")
    defer ctx.deinit()
    assert_true(ctx.stdlib_root.as_view() == "C:/x/build/stdlib", "backslashes -> forward slashes")

    let f = module_fqn(&ctx, "C:\\x\\build\\stdlib\\core\\string.f")
    defer f.deinit()
    assert_true(f.as_view() == "core.string", "stdlib file under a backslash root")
}
