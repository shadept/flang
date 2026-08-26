// flang_analysis - the front half of the pipeline as a library: source
// text in, a checked `AnalyzedUnit` out (AST + type-check result +
// combined parse and check diagnostics). This is the single analysis
// entry point shared by every front-end exe - `flang build`, `flang test`,
// and the LSP - each of which is a thin `main` over `analyze`.
// Lowering and the build itself live one layer up, in `flang_driver`.
//
// The library owns the pipeline but not its edges: file reading and
// diagnostic *rendering* are the caller's concern (the LSP reads buffers
// and emits protocol diagnostics; the CLI reads files and prints to a
// terminal).
//
// Ownership: an `AnalyzedUnit` owns its `source`. The projected AST stores
// string views into the source buffer (flang_parser/projector.f), so the
// source must outlive the `Module`. Tokens and the CST are dropped inside
// `analyze` once the AST exists.

import std.allocator
import std.dict
import std.list
import std.option
import std.set
import std.string
import std.string_builder
import std.test
import std.io.file
import std.result
import std.time
import flang_parser.lexer
import flang_parser.parser
import flang_parser.projector
import flang_parser.ast
import flang_parser.comptime
import flang_core.diagnostic
import flang_core.span
import flang_typer.checker
import flang_typer.template_expand
import flang_typer.result
import flang_analysis.resolver
import flang_analysis.project
import flang_analysis.demand

// A fully analysed compilation unit. `checked` is false when the source
// failed to parse - `result` is then an empty placeholder.
pub type AnalyzedUnit = struct {
    source: OwnedString
    module: Module
    result: TypeCheckResult
    checked: bool
    diagnostics: List(Diagnostic)
}

// Analyse source text: lex → parse → project → type-check. Consumes
// `source` (the unit owns it). `path` labels the module for FQN
// construction and diagnostics; it need not name a real file.
pub fn analyze(source: OwnedString, path: String, allocator: &Allocator? = null) AnalyzedUnit {
    let diagnostics: List(Diagnostic) = list(0, allocator)
    const src = source.as_view()

    let lx = lexer(src, allocator)
    let tokens = lx.tokenize()
    let p = parser(tokens, allocator)
    const cst = p.parse_module()
    let module = project_module(cst, 0i32, allocator)

    // Decl-level #if resolves once, before anything walks the decls:
    // only the active branch's declarations survive into collection.
    const cctx = host_ctx()
    flatten_module_decls(&module, &cctx, &diagnostics, allocator)

    // The AST views `source`, not the token structs - tokens and the parser
    // are dead once the Module exists. Drain parse diagnostics first so they
    // survive `p.deinit()`.
    drain_diagnostics(&diagnostics, &p.diagnostics)
    p.deinit()
    tokens.deinit()

    // A file that didn't parse is not type-checked.
    let checked = count_errors(&diagnostics) == 0
    let result = empty_result(allocator)
    if checked {
        let modules: List(Module) = list(1, allocator)
        modules.push(module)
        let paths: List(String) = list(1, allocator)
        paths.push(path)

        let srcs: List(OwnedString) = list(1, allocator)
        srcs.push(from_view(src, allocator))
        let fps: List(OwnedString) = list(1, allocator)
        fps.push(from_view(path, allocator))
        let chk = checker(allocator)
        let gens = template_state(allocator)

        result = check_all(&chk, &modules, &paths, &srcs, &fps, &gens)
        drain_diagnostics(&diagnostics, &chk.diagnostics)

        // ponytail: single-unit analysis leaks the generated chunk modules
        // (their decls were appended to `module`); AnalyzedUnit has no slot.
        gens.forget()
        chk.deinit()
        srcs.deinit()
        fps.deinit()

        // `push` copied the struct; `module` still owns the arena. Forget
        // the alias before freeing the list so the arena isn't double-freed.
        modules.clear()
        modules.deinit()
        paths.deinit()
    }

    return .{
        source = source,
        module = module,
        result = result,
        checked = checked,
        diagnostics = diagnostics,
    }
}

pub fn deinit(self: &AnalyzedUnit) {
    self.diagnostics.deinit()
    self.module.deinit()
    self.source.deinit()
    // ponytail: the TypeCheckResult is leaked - flang_typer has no
    // result.deinit() yet. Fine for one-shot build/test; add result.deinit()
    // before the LSP re-analyses on every keystroke. See docs/known-issues.md.
}

// Error-severity diagnostics only - warnings and hints don't fail a build.
pub fn error_count(self: &AnalyzedUnit) usize {
    return count_errors(&self.diagnostics)
}

// Move every diagnostic from `src` into `dst`. `src.clear()` resets the
// length without deiniting elements, so the moved OwnedString messages are
// owned once (by `dst`) and never double-freed.
fn drain_diagnostics(dst: &List(Diagnostic), src: &List(Diagnostic)) {
    dst.push_all(src.as_slice())
    src.clear()
}

fn count_errors(diags: &List(Diagnostic)) usize {
    let n: usize = 0
    for i in 0..diags.len {
        if diags[i].severity == Severity.Error { n = n + 1 }
    }
    return n
}

// ─────────────────────────────────────────────────────────────────────
// Multi-module project analysis
//
// `analyze_project` discovers the full module set by following imports
// from the entry sources (plus the auto-imported core prelude), resolving
// each against `ctx`, then type-checks every module together via one
// `check_all`. Each module's source is owned by the returned unit; the
// AST views into it (flang_parser/projector.f), so the sources outlive
// the modules.
// ─────────────────────────────────────────────────────────────────────

// A type-checked multi-module project. Parallel lists are keyed by file
// id (a module's index): `sources[i]` / `file_paths[i]` back `modules[i]`,
// whose registered FQN is `fqns[i]`.
pub type AnalyzedProject = struct {
    sources: List(OwnedString)
    fqns: List(OwnedString)
    file_paths: List(OwnedString)
    modules: List(Module)
    // Per module: was it one of the project's own files, as opposed to the
    // stdlib or a dependency. Kept because a re-check has to rebuild the
    // checker with the same project boundary the first one used.
    project_origin: List(bool)
    // Sources and ASTs that a re-parse replaced, held until the unit is
    // dropped. A `TypeCheckResult` holds string views into the source it was
    // checked from (nominal FQNs, field names) and AST pointers into the
    // module, so a result outlives the buffers it was built over.
    retired_sources: List(OwnedString)
    retired_modules: List(Module)
    result: TypeCheckResult
    checked: bool
    diagnostics: List(Diagnostic)
    // Template expansion output: the chunk modules whose decls were
    // appended into `modules` (kept alive here) and the per-origin
    // generated text (`--emit-generated`). `sources`/`file_paths` also
    // hold one padded entry per chunk, after the real files.
    generated: TemplateOutput

    // Wall time of the front half, for `--timings`. `parse_ns` covers the
    // import-graph walk (read + lex + parse); `check_ns` covers template
    // expansion, resolution and inference.
    parse_ns: u64
    check_ns: u64
}

// `overrides` supplies a buffer to use in place of the file on disk, for
// every path it names - an editor's unsaved text. `flang build` passes
// none. See `read_source` for the key convention.
pub fn analyze_project(ctx: &ResolveCtx, entries: &List(OwnedString),
        overrides: &Dict(String, String)? = null,
        allocator: &Allocator? = null) AnalyzedProject {
    let diagnostics: List(Diagnostic) = list(0, allocator)
    let sources: List(OwnedString) = list(0, allocator)
    let fqns: List(OwnedString) = list(0, allocator)
    let file_paths: List(OwnedString) = list(0, allocator)
    let modules: List(Module) = list(0, allocator)
    const parse_start = monotonic_ns()

    // BFS over the import graph, deduplicated by file path.
    let queue: List(OwnedString) = list(0, allocator)
    let seen: Set(String) = set(allocator)
    for i in 0..entries.len {
        enqueue_copy(&queue, &seen, entries[i].as_view())
    }
    // Everything enqueued from here on is stdlib, a dependency or a
    // transitive import - never a project file. `[imports].global` applies
    // to project files only, so the boundary has to be recorded before the
    // seeds run.
    let project_count = queue.len
    let project_origin: List(bool) = list(0, allocator)
    seed_globals(ctx, &queue, &seen, &diagnostics, allocator)
    seed_prelude(ctx, &queue, &seen, allocator)
    seed_stdlib(ctx, &queue, &seen, allocator)

    // Import edges as they resolve. `edge_to` holds paths, not indices: the
    // target module may not be parsed yet when the edge is seen.
    let edge_from = list(0, allocator)
    defer edge_from.deinit()
    let edge_to = list(0, allocator)
    defer edge_to.deinit()

    let qi: usize = 0
    while qi < queue.len {
        let path = queue[qi].as_view()
        let is_project = qi < project_count
        qi = qi + 1
        let src_opt = read_source(path, overrides)
        if src_opt.is_none() {
            const msg = $"cannot read source `{path}`"
            diagnostics.push(error("E0001", msg, none_span()))
            continue
        }
        let src = src_opt.unwrap()
        let fid = modules.len as i32
        let module = parse_to_module(src.as_view(), fid, &ctx.comptime, &diagnostics, allocator)
        let fqn = module_fqn(ctx, path, allocator)
        enqueue_imports(ctx, &module, modules.len, &queue, &seen, &edge_from, &edge_to, &diagnostics, allocator)
        sources.push(src)
        file_paths.push(from_view(path))
        fqns.push(fqn)
        modules.push(module)
        project_origin.push(is_project)
    }

    queue.deinit()
    seen.deinit()
    const parse_ns = elapsed_ns(parse_start)

    let unit = AnalyzedProject {
        sources = sources,
        fqns = fqns,
        file_paths = file_paths,
        modules = modules,
        project_origin = project_origin,
        retired_sources = list(0, allocator),
        retired_modules = list(0, allocator),
        result = empty_result(allocator),
        checked = false,
        diagnostics = diagnostics,
        generated = empty_template_output(allocator),
        parse_ns = parse_ns,
        check_ns = 0,
    }
    const check_start = monotonic_ns()
    check_project(&unit, ctx, &edge_from, &edge_to, allocator)
    unit.check_ns = elapsed_ns(check_start)
    return unit
}

// Run the checker over the module set `self` already holds and install the
// result. `edge_from`/`edge_to` are the import graph, used to order the walk.
//
// Safe to call more than once on the same unit: expansion leaves one padded
// `sources`/`file_paths` entry per generated chunk, and those are trimmed off
// first so a second run starts from the state the first one saw.
fn check_project(self: &AnalyzedProject, ctx: &ResolveCtx, edge_from: &List(usize),
        edge_to: &List(OwnedString), allocator: &Allocator?) {
    // Expansion appends one source per generated chunk. Those buffers are
    // retired, since a result from a previous check holds string views into
    // them; the matching `file_paths` entries are freed, because
    // `TypeCheckResult` keeps its own copies of paths.
    while self.sources.len > self.modules.len {
        const gone = self.sources.pop()
        if gone.is_some() { self.retired_sources.push(gone.unwrap()) }
    }
    trim_owned(&self.file_paths, self.modules.len)

    self.checked = count_errors(&self.diagnostics) == 0
    if !self.checked { return }

    let path_views = self.fqns.map(fn(s: OwnedString) { s.as_view() })
    defer path_views.deinit()
    let order = visit_order(&self.file_paths, &path_views, edge_from, edge_to, allocator)
    defer order.deinit()

    let chk = checker(allocator)
    let gens = template_state(allocator)
    chk.set_comptime_ctx(ctx.comptime)
    chk.set_project_globals(&ctx.global_imports, &self.project_origin)
    self.result = check_all(&chk, &self.modules, &path_views, &self.sources, &self.file_paths,
        &gens, Some(&order))
    drain_diagnostics(&self.diagnostics, &chk.diagnostics)
    self.generated = gens.take_output()
    gens.deinit()
    chk.deinit()
}

// Drop trailing entries until `xs` holds `n`, freeing each one.
fn trim_owned(xs: &List(OwnedString), n: usize) {
    while xs.len > n {
        const gone = xs.pop()
        if gone.is_some() { gone.unwrap().deinit() }
    }
}

// Check the project again, re-parsing only what is stale and reusing every
// other module's AST.
//
// A module is stale when the caller names it in `dirty`, or when template
// expansion appended generated declarations to it - those declarations live
// in the AST, so reusing one would stack a second copy on the next expansion.
// If the first parse produced any diagnostic at all, everything is stale:
// diagnostics are not tracked per module, so the ones belonging to modules
// that are still good cannot be told apart from the rest.
//
// The module SET is assumed unchanged - same files, same imports. Editing a
// module's imports is what would break that, and re-running `analyze_project`
// is the answer until the loader itself becomes incremental.
pub fn reanalyze(self: &AnalyzedProject, ctx: &ResolveCtx, dirty: &Set(String),
        overrides: &Dict(String, String)? = null, allocator: &Allocator? = null) {
    const reparse_all = self.diagnostics.len > 0
    let stale: Set(String) = set(allocator)
    defer stale.deinit()
    for &e in self.generated.emitted {
        stale.add(e.origin_path)
    }

    const parse_start = monotonic_ns()
    let srcs = &self.sources
    let mods = &self.modules
    for i in 0..self.modules.len {
        const path = self.file_paths[i].as_view()
        if !reparse_all and !dirty.contains(path) and !stale.contains(path) { continue }
        const fresh = read_source(path, overrides)
        if fresh.is_none() {
            const msg = $"cannot read source `{path}`"
            self.diagnostics.push(error("E0001", msg, none_span()))
            continue
        }
        self.retired_sources.push(srcs[i])
        self.retired_modules.push(mods[i])
        srcs[i] = fresh.unwrap()
        mods[i] = parse_to_module(srcs[i].as_view(), i as i32, &ctx.comptime,
            &self.diagnostics, allocator)
    }
    self.parse_ns = elapsed_ns(parse_start)

    // ponytail: re-walks the whole import graph, one `resolve_import` per
    // import. Cache the edges on the unit if a profile shows it.
    let edge_from = list(0, allocator)
    defer edge_from.deinit()
    let edge_to = list(0, allocator)
    defer edge_to.deinit()
    collect_edges(ctx, &self.modules, &edge_from, &edge_to, allocator)

    self.generated.deinit()
    self.generated = empty_template_output(allocator)

    const check_start = monotonic_ns()
    check_project(self, ctx, &edge_from, &edge_to, allocator)
    self.check_ns = elapsed_ns(check_start)
}

// Resolve every module's imports into `from -> to` edges. The BFS records
// these for free on a first analysis; a re-check has to ask again.
fn collect_edges(ctx: &ResolveCtx, modules: &List(Module), edge_from: &List(usize),
        edge_to: &List(OwnedString), alloc: &Allocator?) {
    for i in 0..modules.len {
        for d in modules[i].decls {
            d match {
                Import(id) => {
                    const r = resolve_import(ctx, &id.path, alloc)
                    if r.is_some() {
                        edge_from.push(i)
                        edge_to.push(r.unwrap())
                    }
                },
                _ => {},
            }
        }
    }
}

// The multi-module analogue of `analyze` for in-memory sources: the given
// sources ARE the module set - no import discovery, no file IO. `fqns[i]`
// is both `srcs[i]`'s module FQN and its diagnostic label. Test support:
// lowering suites use it to place well-known modules (core.option,
// core.string) next to the module under test. Consumes `srcs`.
pub fn analyze_source_set(srcs: List(OwnedString), fqns: &List(String), allocator: &Allocator? = null) AnalyzedProject {
    let diagnostics: List(Diagnostic) = list(0, allocator)
    let owned_fqns: List(OwnedString) = list(fqns.len, allocator)
    let file_paths: List(OwnedString) = list(fqns.len, allocator)
    let modules: List(Module) = list(srcs.len, allocator)
    const host = host_ctx()
    for i in 0..srcs.len {
        modules.push(parse_to_module(srcs[i].as_view(), i as i32, &host, &diagnostics, allocator))
        owned_fqns.push(from_view(fqns[i]))
        file_paths.push(from_view(fqns[i]))
    }

    let checked = count_errors(&diagnostics) == 0
    let result = empty_result(allocator)
    let generated = empty_template_output(allocator)
    if checked {
        let chk = checker(allocator)
        let gens = template_state(allocator)
        result = check_all(&chk, &modules, fqns, &srcs, &file_paths, &gens)
        drain_diagnostics(&diagnostics, &chk.diagnostics)
        generated = gens.take_output()
        gens.deinit()
        chk.deinit()
    }

    let no_origin: List(bool) = list(0, allocator)
    return AnalyzedProject {
        sources = srcs,
        fqns = owned_fqns,
        file_paths = file_paths,
        modules = modules,
        project_origin = no_origin,
        retired_sources = list(0, allocator),
        retired_modules = list(0, allocator),
        result = result,
        checked = checked,
        diagnostics = diagnostics,
        generated = generated,
        parse_ns = 0,
        check_ns = 0,
    }
}

pub fn deinit(self: &AnalyzedProject) {
    self.retired_modules.deinit()
    self.retired_sources.deinit()
    self.project_origin.deinit()
    self.diagnostics.deinit()
    self.generated.deinit()
    self.modules.deinit()
    self.fqns.deinit()
    self.file_paths.deinit()
    self.sources.deinit()
    // ponytail: the TypeCheckResult is leaked - same as AnalyzedUnit, no
    // result.deinit() yet. Fine for one-shot build. See docs/known-issues.md.
}

// Write each origin's generated text to `<origin>.generated.f`
// (`--emit-generated`). Debug output only - nothing ever reads it back
// (RFC-021 §4). Returns how many files were written.
pub fn write_generated(self: &AnalyzedProject) usize {
    let written: usize = 0
    for &e in self.generated.emitted {
        const path = generated_path(e.origin_path)
        defer path.deinit()
        let f = open_file(path.as_view(), FileMode.Write) match {
            Ok(f) => f,
            Err(_) => continue,
        }
        const w = f.write(e.text.as_view())
        const _c = close_file(&f)
        if w.is_ok() { written = written + 1 }
    }
    return written
}

// Total error-severity diagnostics across every module.
pub fn project_error_count(self: &AnalyzedProject) usize {
    return count_errors(&self.diagnostics)
}


fn parse_to_module(src: String, file_id: i32, target: &ComptimeCtx, diags: &List(Diagnostic), alloc: &Allocator?) Module {
    let lx = lexer(src, alloc)
    let tokens = lx.tokenize()
    let p = parser(tokens, alloc)
    const cst = p.parse_module()
    let module = project_module(cst, file_id, alloc)
    flatten_module_decls(&module, target, diags, alloc)
    drain_diagnostics(diags, &p.diagnostics)
    p.deinit()
    tokens.deinit()
    return module
}

// Queue every module `m` imports, recording `from -> imported` so the checker
// can be given a dependency-respecting visit order. `enqueue_owned` consumes
// the resolved path, so the edge keeps its own copy.
fn enqueue_imports(ctx: &ResolveCtx, m: &Module, from: usize, queue: &List(OwnedString), seen: &Set(String),
        edge_from: &List(usize), edge_to: &List(OwnedString), diags: &List(Diagnostic), alloc: &Allocator?) {
    for d in m.decls {
        d match {
            Import(id) => {
                let r = resolve_import(ctx, &id.path, alloc)
                r match {
                    Some(p) => {
                        edge_from.push(from)
                        edge_to.push(from_view(p.as_view()))
                        enqueue_owned(queue, seen, p)
                    },
                    None => push_unresolved(diags, &id, alloc),
                }
            },
            _ => {},
        }
    }
}

// `flang.toml`'s `[imports].global`. Loading the module is only half the
// job - `build_visibility` is what actually puts it in each project file's
// scope; this side just guarantees it is in the module set to be found.
fn seed_globals(ctx: &ResolveCtx, queue: &List(OwnedString), seen: &Set(String), diags: &List(Diagnostic), alloc: &Allocator?) {
    for &g in ctx.global_imports {
        let segs = split(g.as_view(), '.')
        let r = resolve_import(ctx, &segs, alloc)
        segs.deinit()
        r match {
            Some(p) => enqueue_owned(queue, seen, p),
            None => {
                const msg = $"unresolved global import `{g.as_view()}` from flang.toml [imports].global"
                diags.push(error("E0001", msg, none_span()))
            },
        }
    }
}

fn seed_prelude(ctx: &ResolveCtx, queue: &List(OwnedString), seen: &Set(String), alloc: &Allocator?) {
    let segs: List(String) = list(2, alloc)
    segs.push("core")
    segs.push("prelude")
    let r = resolve_import(ctx, &segs, alloc)
    segs.deinit()
    r match {
        Some(p) => enqueue_owned(queue, seen, p),
        None => {},
    }
}

// The reference compiler compiles every program against the whole stdlib
// regardless of imports, and lenient type resolution in the checker relies
// on every stdlib nominal being registered - so the BFS seeds the full
// stdlib tree.
// ponytail: typechecks all of std on every build; prune to the import
// closure once stdlib type visibility turns strict.
fn seed_stdlib(ctx: &ResolveCtx, queue: &List(OwnedString), seen: &Set(String), alloc: &Allocator?) {
    if ctx.stdlib_root.as_view().len == 0 { return }
    let pattern = $"{ctx.stdlib_root.as_view()}/**/*.f"
    let found = glob_sources(pattern.as_view(), alloc)
    pattern.deinit()
    for i in 0..found.len {
        let norm = normalize_sep(found[i].as_view(), alloc)
        enqueue_owned(queue, seen, norm)
    }
    deinit_source_list(&found)
}

// The text to compile for `path`: a supplied buffer when one stands in
// for that file, the file on disk otherwise. Keys are the forward-slash
// paths the resolver produces (`resolver.normalize_sep`) - a caller that
// spells a key any other way misses silently and gets the stale file.
//
// The returned buffer is a copy: the AST views into whichever source the
// project owns, and an override's storage belongs to the caller.
fn read_source(path: String, overrides: &Dict(String, String)?) OwnedString? {
    if overrides.is_some() {
        let hit = overrides.unwrap().get(path)
        if hit.is_some() { return Some(from_view(hit.unwrap())) }
    }
    return read_text(path)
}

// Turn the path-keyed import edges into module indices, then order the set.
// An edge naming a path that never became a module (an unreadable file) is
// dropped; every module is still emitted exactly once.
fn visit_order(file_paths: &List(OwnedString), fqns: &List(String), edge_from: &List(usize),
        edge_to: &List(OwnedString), alloc: &Allocator?) List(usize) {
    let index_of: Dict(String, usize) = dict(alloc)
    defer index_of.deinit()
    for i in 0..file_paths.len {
        index_of.set(file_paths[i].as_view(), i)
    }
    let edges = list(edge_from.len, alloc)
    defer edges.deinit()
    for i in 0..edge_from.len {
        const to = index_of.get(edge_to[i].as_view())
        if to.is_none() { continue }
        edges.push(ImportEdge { from = edge_from[i], to = to.unwrap() })
    }
    return demand_order(fqns.len, fqns, &edges, alloc)
}

fn enqueue_copy(queue: &List(OwnedString), seen: &Set(String), path: String) {
    if seen.contains(path) { return }
    queue.push(from_view(path))
    seen.add(queue[queue.len - 1].as_view())
}

fn enqueue_owned(queue: &List(OwnedString), seen: &Set(String), owned: OwnedString) {
    if seen.contains(owned.as_view()) {
        owned.deinit()
        return
    }
    queue.push(owned)
    seen.add(queue[queue.len - 1].as_view())
}

fn push_unresolved(diags: &List(Diagnostic), id: &ImportDecl, alloc: &Allocator?) {
    let dotted = dot_join(&id.path, alloc)
    const msg = $"unresolved import `{dotted.as_view()}`"
    dotted.deinit()
    diags.push(error("E0001", msg, id.span))
}

// Tests

test "an override stands in for a file that is not on disk" {
    let ov: Dict(String, String) = dict()
    defer ov.deinit()
    ov.set("no/such/file.f", "fn main() i32 { return 0 }\n")
    let got = read_source("no/such/file.f", Some(&ov))
    assert_true(got.is_some(), "the override supplied the text")
    let text = got.unwrap()
    defer text.deinit()
    assert_true(text.as_view() == "fn main() i32 { return 0 }\n", "and it is the buffer verbatim")
}

test "a path no override names falls through to the file on disk" {
    let ov: Dict(String, String) = dict()
    defer ov.deinit()
    ov.set("other.f", "fn other() i32 { return 1 }\n")
    assert_true(read_source("no/such/file.f", Some(&ov)).is_none(), "an unnamed path reads from disk, and misses")
    assert_true(read_source("no/such/file.f", null).is_none(), "so does no override map at all")
}
