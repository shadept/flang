// Import resolution: the two symmetric halves of the C# compiler's module machinery, ported for the
// self-host driver.
//
//   - `resolve_import` maps a dotted import (`flang_parser.lexer`) to an
//     existing source file, trying project-name, dependency-name and
//     include-path rules in that order (mirrors
//     `Compilation.TryResolveImportPath`).
//   - `module_fqn` is the inverse: a source file path becomes the dotted
//     module name its symbols register under, so the import side and the
//     symbol side agree (mirrors `TemplateExpander.DeriveModulePath`).
//
// Resolution is flat and path-only: no transitive deps, no lockfile. Paths are normalised to
// forward slashes before any prefix comparison.

import std.allocator
import std.list
import std.option
import std.path
import std.result
import std.string
import std.string_builder
import std.io.fs
import std.io.file
import std.test
import flang_analysis.project
import flang_parser.comptime

// One direct dependency: its `[project].name` (its import namespace) and its resolved source root.
pub type DepRoot = struct {
    name: OwnedString
    root: OwnedString
}

// Everything import resolution needs about the project under build. All roots are stored normalised
// (forward slashes, no trailing separator).
pub type ResolveCtx = struct {
    project_name: OwnedString
    project_source_root: OwnedString
    deps: List(DepRoot)
    stdlib_root: OwnedString
    cwd: OwnedString
    // `flang.toml`'s `[imports].global`: dotted module names every PROJECT-origin file imports
    // implicitly. The stdlib and dependencies stay isolated from per-project config, so this never
    // applies to them.
    global_imports: List(OwnedString)
    // Compile-time context #if conditions evaluate against during this build. Host by default;
    // `--target-os`/`--target-arch` override it.
    comptime: ComptimeCtx
    // `flang.toml [project].kind = "lib"`. Decides the unused-function roots (W1003): a library's
    // `pub fn`s are its API and count as used; an executable's functions must be reachable from
    // `main`, `pub` or not.
    lib_kind: bool
    // Lazy body demand (RFC-022 §6): body slots run only for the demand set - the project's own
    // modules plus everything transitively imported from them - instead of every loaded module. Off
    // by default; the CLI turns it on for builds.
    lazy_bodies: bool
    // W1003 unused-function analysis. Off by default: a build does not check `test {}` bodies, so
    // its reachability is blind to test-only use and the warning is opt-in there (`--warn-unused`).
    // The LSP checks test bodies and turns it on with full edges.
    warn_unused: bool
    // Check the project's own `test {}` bodies. Off by default; `flang test`, `flang check` and the
    // LSP turn it on. It widens the check rather than the module set: the same modules load either
    // way, but test-only calls, overload picks and instantiations are recorded only when it is on.
    check_tests: bool
}

// Scoped mutability: turns lazy body demand on or off for every analysis run through this context.
pub fn set_lazy(self: &ResolveCtx, on: bool) {
    self.lazy_bodies = on
}

// Scoped mutability: turns the W1003 unused-function analysis on or off.
pub fn set_warn_unused(self: &ResolveCtx, on: bool) {
    self.warn_unused = on
}

// Scoped mutability: turns `test {}` body checking on or off.
pub fn set_check_tests(self: &ResolveCtx, on: bool) {
    self.check_tests = on
}

// Scoped mutability: installs the build's compile-time context (a `--target-os`/`--target-arch`
// override). Fields are writable only here.
pub fn set_comptime(self: &ResolveCtx, c: ComptimeCtx) {
    self.comptime = c
}

pub fn deinit(self: &ResolveCtx) {
    self.project_name.deinit()
    self.project_source_root.deinit()
    for &d in self.deps {
        d.name.deinit()
        d.root.deinit()
    }
    self.deps.deinit()
    self.stdlib_root.deinit()
    self.cwd.deinit()
    for &g in self.global_imports { g.deinit() }
    self.global_imports.deinit()
}

// Resolve a dotted import to an existing file path, or null when no rule matches an existing file.
// The returned string is owned by the caller.
pub fn resolve_import(ctx: &ResolveCtx, segs: &List(String),
    allocator: &Allocator? = null) OwnedString? {
    // Project rule: first segment is the project name.
    if segs.len > 1 and segs[0] == ctx.project_name.as_view() {
        let p = join_module_path(ctx.project_source_root.as_view(), segs, 1, allocator)
        if exists(p.as_view()) {
            return Some(p)
        }
        p.deinit()
    }

    // Dependency rule: first segment names a direct dependency.
    if segs.len > 1 {
        for &d in ctx.deps {
            if segs[0] == d.name.as_view() {
                let p = join_module_path(d.root.as_view(), segs, 1, allocator)
                if exists(p.as_view()) {
                    return Some(p)
                }
                p.deinit()
            }
        }
    }

    // Include rule: stdlib first, then the working directory.
    let p1 = join_module_path(ctx.stdlib_root.as_view(), segs, 0, allocator)
    if exists(p1.as_view()) {
        return Some(p1)
    }
    p1.deinit()

    let p2 = join_module_path(ctx.cwd.as_view(), segs, 0, allocator)
    if exists(p2.as_view()) {
        return Some(p2)
    }
    p2.deinit()

    return null
}

// Derive the dotted module name a source file's symbols register under. Classifies the path under
// project / dependency / stdlib roots in the same order `resolve_import` tries them; an
// unclassified path falls back to its bare file stem.
pub fn module_fqn(ctx: &ResolveCtx, path: String, allocator: &Allocator? = null) OwnedString {
    let norm = normalize_sep(path, allocator)
    defer norm.deinit()
    let np = norm.as_view()

    let pr = strip_root(np, ctx.project_source_root.as_view())
    if pr.is_some() {
        return dotted_with_prefix(ctx.project_name.as_view(), pr.unwrap(), allocator)
    }

    for i in 0..ctx.deps.len {
        let dr = strip_root(np, ctx.deps[i].root.as_view())
        if dr.is_some() {
            return dotted_with_prefix(ctx.deps[i].name.as_view(), dr.unwrap(), allocator)
        }
    }

    let sr = strip_root(np, ctx.stdlib_root.as_view())
    if sr.is_some() {
        return dotted(sr.unwrap(), allocator)
    }

    let cr = strip_root(np, ctx.cwd.as_view())
    if cr.is_some() {
        return dotted(cr.unwrap(), allocator)
    }
    return dotted(basename(np), allocator)
}

// `base/seg.../tail.f` from import segments, joining with forward slashes.
pub fn join_module_path(base: String, segs: &List(String), start: usize,
    allocator: &Allocator? = null) OwnedString {
    let sb = string_builder(0, allocator)
    defer sb.deinit()
    sb.append(base)
    for i in start..segs.len {
        sb.append('/')
        sb.append(segs[i])
    }
    sb.append(".f")
    return sb.to_string()
}

// Build a resolution context for `proj` under the current directory. `stdlib_root` is the include
// root for `std.*` / `core.*` (the value of the build's `--stdlib-path`). Each dependency's source
// root is derived from its own manifest, exactly as the C# compiler does.
pub fn resolve_ctx(proj: &Project, stdlib_root: String, allocator: &Allocator? = null) ResolveCtx {
    return resolve_ctx_at(proj, ".", stdlib_root, allocator)
}

// Build a resolution context for `proj` rooted at `project_dir` instead of the current directory.
// Dependency paths in the manifest are relative to the manifest's own directory, so they are joined
// under `project_dir` before their source roots are derived. The LSP analyzes projects anywhere in
// the workspace this way; a build passes `"."`.
pub fn resolve_ctx_at(proj: &Project, project_dir: String, stdlib_root: String,
    allocator: &Allocator? = null) ResolveCtx {
    let deps = list(0, allocator)
    for &d in proj.deps {
        let dep_dir = join_under(project_dir, d.path.as_view(), allocator)
        let root = normalized_owned(dep_source_root(dep_dir.as_view(), allocator), allocator)
        dep_dir.deinit()
        deps.push(DepRoot { name = from_view(d.name.as_view()), root = root })
    }
    let globals: List(OwnedString) = list(proj.global_imports.len, allocator)
    for &g in proj.global_imports {
        globals.push(from_view(g.as_view()))
    }
    return ResolveCtx {
        project_name = from_view(proj.name.as_view()),
        project_source_root = normalized_owned(source_root(project_dir, proj.source.as_view(),
                allocator), allocator),
        deps = deps,
        stdlib_root = normalize_sep(stdlib_root, allocator),
        cwd = normalize_sep(project_dir, allocator),
        global_imports = globals,
        comptime = host_ctx(),
        lib_kind = proj.kind match {
            Lib => true
            _ => false
        },
        lazy_bodies = false,
        warn_unused = false,
        check_tests = false,
    }
}

// `rel` joined under `dir`, unless `rel` is already absolute (`/x` or `c:/x`) or `dir` is the
// current directory.
fn join_under(dir: String, rel: String, allocator: &Allocator?) OwnedString {
    if dir == "." or dir.len == 0 or is_absolute(rel) {
        return from_view(rel, allocator)
    }
    let sb = string_builder(dir.len + rel.len + 1, allocator)
    defer sb.deinit()
    sb.append(dir)
    sb.append('/')
    sb.append(rel)
    return sb.to_string()
}

fn is_absolute(path: String) bool {
    if path.len > 0 and (path[0] == '/' or path[0] == '\\') {
        return true
    }
    return path.len > 1 and path[1] == ':'
}

// A resolution context for a single-file build: no project name or deps, so only the stdlib and
// working-directory include rules apply.
pub fn single_file_ctx(stdlib_root: String, allocator: &Allocator? = null) ResolveCtx {
    let deps: List(DepRoot) = list(0, allocator)
    let globals: List(OwnedString) = list(0, allocator)
    return ResolveCtx {
        project_name = from_view(""),
        project_source_root = from_view(""),
        deps = deps,
        stdlib_root = normalize_sep(stdlib_root, allocator),
        cwd = from_view("."),
        global_imports = globals,
        comptime = host_ctx(),
        lib_kind = false,
        lazy_bodies = false,
        warn_unused = false,
        check_tests = false,
    }
}

// A dependency's source root: read its manifest and take the static prefix of its `source` glob;
// fall back to `<dep>/src` when unreadable.
fn dep_source_root(dep_dir: String, allocator: &Allocator?) OwnedString {
    let manifest = $"{dep_dir}/flang.toml"
    defer manifest.deinit()
    let text = read_text(manifest.as_view())
    if text.is_none() {
        return source_root(dep_dir, "src/**/*.f", allocator)
    }
    let t = text.unwrap()
    defer t.deinit()
    let dp = parse_project(t.as_view(), allocator)
    defer dp.deinit()
    return source_root(dep_dir, dp.source.as_view(), allocator)
}

// The static (glob-free) prefix of `source_glob` under `project_dir`. `.` as the directory means
// "relative to here", so it is not prefixed; a glob with no static prefix resolves to the directory
// itself.
fn source_root(project_dir: String, source_glob: String, allocator: &Allocator?) OwnedString {
    let segs = split(source_glob, '/')
    defer segs.deinit()
    let sb = string_builder(0, allocator)
    defer sb.deinit()
    let wrote = false
    if project_dir != "." and project_dir.len > 0 {
        sb.append(project_dir)
        wrote = true
    }
    for s in segs {
        if contains(s, "*") {
            break
        }
        if contains(s, "?") {
            break
        }
        if wrote {
            sb.append('/')
        }
        sb.append(s)
        wrote = true
    }
    let out = sb.to_string()
    if !wrote {
        out.deinit()
        return from_view(".")
    }
    return out
}

// Read a whole file as text, or null when it cannot be opened or read.
pub fn read_text(path: String) OwnedString? {
    let r = open_file(path, FileMode.Read)
    if r.is_err() {
        return null
    }
    let f = r.unwrap()
    let rd = read_all(&f)
    close_file(&f)
    if rd.is_err() {
        return null
    }
    return Some(rd.unwrap())
}

// Internal helpers

// Normalise a path to the forward-slash convention every `ResolveCtx` comparison assumes.
pub fn normalize_sep(path: String, allocator: &Allocator? = null) OwnedString {
    let sb = string_builder(0, allocator)
    defer sb.deinit()
    sb.append_replaced(path, "\\", "/")
    return sb.to_string()
}

// Normalise an owned path to forward slashes, freeing the input. Keeps the `ResolveCtx` roots in
// the single separator convention `strip_root` compares against, so an absolute or backslashed root
// (e.g. an argv[0]-derived stdlib path on Windows) classifies the same as a forward-slash one.
fn normalized_owned(s: OwnedString, allocator: &Allocator?) OwnedString {
    let n = normalize_sep(s.as_view(), allocator)
    s.deinit()
    return n
}

// One spelling for one file: forward slashes, absolute (joined under the current directory when
// relative), `.` and `..` segments folded lexically, and a lowercased drive letter. Symlinks are
// not resolved. Module identity during loading compares this spelling, so the same file reached
// through differently written roots (`io/file.f`, `./io/file.f`, `../std/io/file.f`, a drive-cased
// absolute) counts as one module.
pub fn canon_path(p: String, allocator: &Allocator? = null) OwnedString {
    let norm = normalize_sep(p, allocator)
    if !is_absolute(norm.as_view()) {
        const wd = cwd(allocator)
        if wd.is_ok() {
            let base = wd.unwrap()
            const joined = $"{base.as_view()}/{norm.as_view()}"
            base.deinit()
            norm.deinit()
            norm = normalize_sep(joined.as_view(), allocator)
            joined.deinit()
        }
    }
    return fold_dots(norm, allocator)
}

// Resolve `.` and `..` segments of a forward-slash path; consumes the input. A `..` that would
// climb past the root is dropped.
fn fold_dots(p: OwnedString, alloc: &Allocator?) OwnedString {
    const v = p.as_view()
    let segs = split(v, '/')
    defer segs.deinit()
    let kept: List(String) = list(segs.len, alloc)
    defer kept.deinit()
    for s in segs {
        if s == "" or s == "." {
            continue
        }
        if s == ".." {
            const _x = kept.pop()
            continue
        }
        kept.push(s)
    }
    if kept.len == 0 {
        return p
    }

    let sb = string_builder(v.len, alloc)
    defer sb.deinit()
    if v.len > 0 and v[0] == '/' {
        sb.append('/')
    }
    for i in 0..kept.len {
        if i > 0 {
            sb.append('/')
        }
        const s = kept[i]
        if i == 0 and s.len > 1 and s[1] == ':' and s[0] >= 'A' and s[0] <= 'Z' {
            sb.append_byte(s[0] + 32)
            sb.append(s[1..s.len])
        } else {
            sb.append(s)
        }
    }
    p.deinit()
    return sb.to_string()
}

// The part of `path` beneath `root`, or null when `path` is not strictly inside `root`. A separator
// boundary is required so `src` never matches `src2/x.f`.
fn strip_root(path: String, root: String) String? {
    if root.len == 0 {
        return null
    }
    if !starts_with(path, root) {
        return null
    }
    if path.len <= root.len {
        return null
    }
    if path[root.len] != '/' {
        return null
    }
    return Some(path[(root.len + 1)..path.len])
}

// Last path component of `path` with its source extension dropped.
fn basename(path: String) String {
    let start: usize = 0
    let i: usize = 0
    while i < path.len {
        if path[i] == '/' {
            start = i + 1
        }
        i = i + 1
    }
    return strip_source_ext(path[start..path.len])
}

// A source file's module stem: the `.f` extension removed.
fn strip_source_ext(name: String) String {
    if ends_with(name, ".f") {
        return name[0..(name.len - 2)]
    }
    return name
}

fn dotted(rel: String, allocator: &Allocator?) OwnedString {
    let sb = string_builder(0, allocator)
    defer sb.deinit()
    append_dotted(&sb, rel)
    return sb.to_string()
}

fn dotted_with_prefix(prefix: String, rel: String, allocator: &Allocator?) OwnedString {
    let sb = string_builder(0, allocator)
    defer sb.deinit()
    sb.append(prefix)
    sb.append('.')
    append_dotted(&sb, rel)
    return sb.to_string()
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
    let globals: List(OwnedString) = list(0)
    return ResolveCtx {
        project_name = from_view("flang_analysis"),
        project_source_root = from_view("lib/flang_analysis/src"),
        deps = deps,
        stdlib_root = from_view("stdlib"),
        cwd = from_view("."),
        global_imports = globals,
        comptime = host_ctx(),
        lib_kind = false,
        lazy_bodies = false,
        warn_unused = false,
        check_tests = false,
    }
}

test "module_fqn: project file -> project-prefixed name" {
    let ctx = fixture_ctx()
    defer ctx.deinit()
    let f = module_fqn(&ctx, "lib/flang_analysis/src/analyze.f")
    defer f.deinit()
    assert_true(f.as_view() == "flang_analysis.analyze", "project root file")
}

test "module_fqn: nested project file dots the subpath" {
    let ctx = fixture_ctx()
    defer ctx.deinit()
    let f = module_fqn(&ctx, "lib/flang_analysis/src/sub/thing.f")
    defer f.deinit()
    assert_true(f.as_view() == "flang_analysis.sub.thing", "nested project file")
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

test "canon_path folds dots, absolutizes, and lowercases the drive" {
    let a = canon_path("C:\\w\\proj\\..\\core\\src\\a.f")
    defer a.deinit()
    assert_true(a.as_view() == "c:/w/core/src/a.f", "dots folded, drive lowered, slashes forward")

    let b = canon_path("c:/w/./x/a.f")
    defer b.deinit()
    assert_true(b.as_view() == "c:/w/x/a.f", "single dots vanish")

    let r = canon_path("src/main.f")
    defer r.deinit()
    assert_true(r.as_view() != "src/main.f", "relative paths absolutize")
    assert_true(ends_with(r.as_view(), "/src/main.f"), "under the current directory")

    let dot = canon_path("./src/main.f")
    defer dot.deinit()
    assert_true(dot.as_view() == r.as_view(), "`./` spelling canonicalizes to the same path")
}

test "resolve_ctx_at roots the project and its deps under the given directory" {
    let proj = parse_project("[project]\nname = \"p\"\nkind = \"lib\"\nsource = \"src/**/*.f\"\n\n[dependencies]\ncore = { path = \"../core\" }\n")
    defer proj.deinit()
    let ctx = resolve_ctx_at(&proj, "w/proj", "stdlib")
    defer ctx.deinit()
    assert_true(ctx.project_source_root.as_view() == "w/proj/src", "source root under the dir")
    assert_true(ctx.cwd.as_view() == "w/proj", "cwd is the project dir")
    assert_true(ctx.deps[0].root.as_view() == "w/proj/../core/src",
        "relative dep path joins under the dir")

    let abs = resolve_ctx_at(&proj, "c:/w", "stdlib")
    defer abs.deinit()
    assert_true(abs.project_source_root.as_view() == "c:/w/src", "absolute dir kept")
}

test "resolve_ctx normalises a backslash stdlib root" {
    // An absolute argv[0]-derived path on Windows arrives with `\` separators; roots must be stored
    // forward-slashed so strip_root classifies stdlib files instead of falling back to their bare
    // stem.
    let proj = parse_project("[project]\nname = \"p\"\nkind = \"exe\"\nsource = \"src/**/*.f\"\n")
    defer proj.deinit()
    let ctx = resolve_ctx(&proj, "C:\\x\\build\\stdlib")
    defer ctx.deinit()
    assert_true(ctx.stdlib_root.as_view() == "C:/x/build/stdlib", "backslashes -> forward slashes")

    let f = module_fqn(&ctx, "C:\\x\\build\\stdlib\\core\\string.f")
    defer f.deinit()
    assert_true(f.as_view() == "core.string", "stdlib file under a backslash root")
}
