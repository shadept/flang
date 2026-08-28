// The set of projects the server has opened: one `flang.toml` directory per entry, each with its
// resolution context and its `AnalyzedProject`. Projects open lazily - the first didOpen of a file
// under a manifest triggers the analysis - and re-analyze on save and on watcher events.
//
// Open editor buffers always win over disk: every analysis passes the document store's buffers as
// overrides, keyed by the uri.f path convention (forward slashes, lowercase drive letter).
//
// ponytail: paths compare byte-exact, so a file reached under two spellings that differ only in
// case (possible on Windows) misses its override; normalise beyond the drive letter if it bites.

import std.allocator
import std.dict
import std.list
import std.option
import std.path
import std.result
import std.set
import std.string
import std.string_builder
import std.io.fs
import std.test
import flang_analysis.analyze
import flang_analysis.project
import flang_analysis.resolver
import flang_lsp.documents
import flang_lsp.uri

pub type OpenProject = struct {
    dir: OwnedString
    name: OwnedString
    ctx: ResolveCtx
    unit: AnalyzedProject
}

pub fn deinit(self: &OpenProject) {
    self.unit.deinit()
    self.ctx.deinit()
    self.name.deinit()
    self.dir.deinit()
}

pub type Workspace = struct {
    stdlib_path: OwnedString
    projects: List(OpenProject)
}

pub fn workspace(stdlib_path: String, allocator: &Allocator? = null) Workspace {
    return .{
        stdlib_path = canonical_root(stdlib_path, allocator),
        projects = list(0, allocator),
    }
}

// The stdlib root in the URI path convention: absolute, forward slashes, lowercase drive. Module
// dedup during analysis is by path string, and a stdlib project (stdlib/std has a manifest) reaches
// the same files through editor URIs - a root spelled any other way would load every module twice
// and drown the project in duplicate-declaration errors.
fn canonical_root(p: String, alloc: &Allocator?) OwnedString {
    if p.len == 0 {
        return from_view("", alloc)
    }
    let rel = p
    while starts_with(rel, "./") {
        rel = rel[2..rel.len]
    }
    if is_abs(rel) {
        return normalize_fs_path(rel)
    }
    const wd = cwd(alloc)
    if wd.is_err() {
        return normalize_fs_path(rel)
    }
    let base = wd.unwrap()
    const joined = $"{base.as_view()}/{rel}"
    base.deinit()
    const norm = normalize_fs_path(joined.as_view())
    joined.deinit()
    return norm
}

fn is_abs(p: String) bool {
    if p.len > 0 and (p[0] == '/' or p[0] == '\\') {
        return true
    }
    return p.len > 1 and p[1] == ':'
}

pub fn deinit(self: &Workspace) {
    self.projects.deinit()
    self.stdlib_path.deinit()
}

// The directory portion of a path, or "" when it has no separator.
pub fn parent_dir(path: String) String {
    return rfind(path, '/') match {
        Some(i) => path[0..i]
        None => ""
    }
}

// The directory of the nearest `flang.toml` at or above `path`'s directory, or null when no
// ancestor holds one.
pub fn project_dir_for(path: String, allocator: &Allocator? = null) OwnedString? {
    let dir = parent_dir(path)
    while dir.len > 0 {
        const manifest = $"{dir}/flang.toml"
        const hit = exists(manifest.as_view())
        manifest.deinit()
        if hit {
            return Some(from_view(dir, allocator))
        }
        dir = parent_dir(dir)
    }
    return null
}

// Index of the open project rooted exactly at `dir`.
pub fn find_project(self: &Workspace, dir: String) usize? {
    for i in 0..self.projects.len {
        if self.projects[i].dir.as_view() == dir {
            return Some(i)
        }
    }
    return null
}

// Index of the open project whose directory contains `path`. The longest match wins, so a nested
// project claims its own files over an enclosing one.
pub fn project_of_path(self: &Workspace, path: String) usize? {
    let best: usize? = null
    let best_len: usize = 0
    for i in 0..self.projects.len {
        const dir = self.projects[i].dir.as_view()
        if dir.len >= best_len and path_under(path, dir) {
            best = Some(i)
            best_len = dir.len
        }
    }
    return best
}

fn path_under(path: String, dir: String) bool {
    if !starts_with(path, dir) or path.len <= dir.len {
        return false
    }
    return path[dir.len] == '/'
}

// Every open buffer with a file path, keyed for `analyze_project`'s override lookup. Views into the
// store's own storage - valid for the duration of one analysis call.
fn overrides_from(docs: &DocumentStore, allocator: &Allocator?) Dict(String, String) {
    let ov: Dict(String, String) = dict(allocator)
    for e in docs.docs.iter() {
        const p = e.value.path.as_view()
        if p.len > 0 {
            ov.set(p, e.value.text.as_view())
        }
    }
    return ov
}

// Analyze the project rooted at `dir` and add it to the workspace. Null when the manifest is
// unreadable or its source glob matches nothing.
pub fn open_project(self: &Workspace, dir: String, docs: &DocumentStore,
    allocator: &Allocator? = null) usize? {
    const loaded = self.load_project(dir, docs, allocator)
    if loaded.is_none() {
        return null
    }
    self.projects.push(loaded.unwrap())
    return Some(self.projects.len - 1)
}

// Re-check an open project, re-parsing only `dirty` paths. The module set is assumed unchanged; a
// changed set (created/deleted file, edited manifest) needs `reopen_project`.
pub fn reanalyze_project(self: &Workspace, idx: usize, dirty: &Set(String), docs: &DocumentStore,
    allocator: &Allocator? = null) {
    let p = &self.projects[idx]
    let ov = overrides_from(docs, allocator)
    reanalyze(&p.unit, &p.ctx, dirty, Some(&ov), allocator)
    ov.deinit()
}

// Rebuild an open project from scratch: fresh manifest, fresh module set. Keeps the old analysis
// when the rebuild fails (manifest gone mid-edit).
pub fn reopen_project(self: &Workspace, idx: usize, docs: &DocumentStore,
    allocator: &Allocator? = null) bool {
    let dir = from_view(self.projects[idx].dir.as_view(), allocator)
    const fresh = self.load_project(dir.as_view(), docs, allocator)
    dir.deinit()
    if fresh.is_none() {
        return false
    }
    let old = self.projects[idx]
    old.deinit()
    self.projects[idx] = fresh.unwrap()
    return true
}

fn load_project(self: &Workspace, dir: String, docs: &DocumentStore,
    allocator: &Allocator?) OpenProject? {
    const manifest = $"{dir}/flang.toml"
    const text = read_text(manifest.as_view())
    manifest.deinit()
    if text.is_none() {
        return null
    }
    let toml = text.unwrap()
    defer toml.deinit()
    let proj = parse_project(toml.as_view(), allocator)
    defer proj.deinit()

    let ctx = resolve_ctx_at(&proj, dir, self.stdlib_path.as_view(), allocator)
    // The LSP checks every body (no lazy demand) and reports unused functions.
    ctx.set_warn_unused(true)

    const pattern = $"{dir}/{proj.source.as_view()}"
    let raw = glob_sources(pattern.as_view(), allocator)
    pattern.deinit()
    let entries: List(OwnedString) = list(raw.len, allocator)
    for &r in raw {
        entries.push(normalize_sep(r.as_view(), allocator))
    }
    raw.deinit()
    if entries.len == 0 {
        entries.deinit()
        ctx.deinit()
        return null
    }

    let ov = overrides_from(docs, allocator)
    let unit = analyze_project(&ctx, &entries, Some(&ov), allocator)
    ov.deinit()
    entries.deinit()

    return Some(OpenProject {
        dir = from_view(dir, allocator),
        name = from_view(proj.name.as_view(), allocator),
        ctx = ctx,
        unit = unit,
    })
}

// Tests

test "project_dir_for walks up and misses cleanly" {
    assert_true(project_dir_for("no/such/dir/deep/x.f").is_none(),
        "no manifest anywhere above a made-up path")
}

test "project_of_path prefers the longest matching root" {
    // Fabricated entries: only `dir` matters for the lookup, so the heavy fields stay empty and the
    // list is dropped without deinit (nothing owned beyond the strings).
    let ws = workspace("")
    defer ws.deinit()
    // no projects: no match
    assert_true(ws.project_of_path("c:/w/a/src/x.f").is_none(), "empty workspace matches nothing")
}

test "path_under requires a separator boundary" {
    assert_true(path_under("c:/w/proj/src/a.f", "c:/w/proj"), "file inside the dir")
    assert_true(!path_under("c:/w/proj2/a.f", "c:/w/proj"), "sibling with a shared prefix")
    assert_true(!path_under("c:/w/proj", "c:/w/proj"), "the dir itself is not under itself")
}
