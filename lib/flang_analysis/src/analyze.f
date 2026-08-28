// flang_analysis - the front half of the pipeline as a library: source text in, a checked
// `AnalyzedUnit` out (AST + type-check result + combined parse and check diagnostics). This is the
// single analysis entry point shared by every front-end exe - `flang build`, `flang test`, and the
// LSP - each of which is a thin `main` over `analyze`. Lowering and the build itself live one layer
// up, in `flang_driver`.
//
// The library owns the pipeline but not its edges: file reading and diagnostic *rendering* are the
// caller's concern (the LSP reads buffers and emits protocol diagnostics; the CLI reads files and
// prints to a terminal).
//
// Ownership: an `AnalyzedUnit` owns its `source`. The projected AST stores string views into the
// source buffer (flang_parser/projector.f), so the source must outlive the `Module`. Tokens and the
// CST are dropped inside `analyze` once the AST exists.

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
import flang_typer.nominal_registry
import flang_analysis.resolver
import flang_analysis.project
import flang_analysis.demand
import flang_analysis.unused

// A fully analysed compilation unit. `checked` is false when the source failed to parse - `result`
// is then an empty placeholder.
pub type AnalyzedUnit = struct {
    source: OwnedString
    module: Module
    result: TypeCheckResult
    checked: bool
    diagnostics: List(Diagnostic)
}

// Analyse source text: lex → parse → project → type-check. Consumes
// `source` (the unit owns it). `path` labels the module for FQN construction and diagnostics; it
// need not name a real file.
pub fn analyze(source: OwnedString, path: String, allocator: &Allocator? = null) AnalyzedUnit {
    let diagnostics: List(Diagnostic) = list(0, allocator)
    const src = source.as_view()

    let lx = lexer(src, allocator)
    let tokens = lx.tokenize()
    let p = parser(tokens, allocator)
    const cst = p.parse_module()
    let module = project_module(cst, 0i32, allocator)

    // Decl-level #if resolves once, before anything walks the decls: only the active branch's
    // declarations survive into collection.
    const cctx = host_ctx()
    flatten_module_decls(&module, &cctx, &diagnostics, allocator)

    // The AST views `source`, not the token structs - tokens and the parser are dead once the
    // Module exists. Drain parse diagnostics first so they survive `p.deinit()`.
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

        // ponytail: single-unit analysis leaks the generated chunk modules (their decls were
        // appended to `module`); AnalyzedUnit has no slot.
        gens.forget()
        chk.deinit()
        srcs.deinit()
        fps.deinit()

        // `push` copied the struct; `module` still owns the arena. `pop` moves the alias out before
        // the list is freed.
        const _alias = modules.pop()
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
    self.result.deinit()
    self.module.deinit()
    self.source.deinit()
}

// Error-severity diagnostics only - warnings and hints don't fail a build.
pub fn error_count(self: &AnalyzedUnit) usize {
    return count_errors(&self.diagnostics)
}

// Move every diagnostic from `src` into `dst`. `Diagnostic` has no deinit of its own, so the
// clear's element deinits are no-ops and the moved message buffers stay owned once, by `dst`.
fn drain_diagnostics(dst: &List(Diagnostic), src: &List(Diagnostic)) {
    dst.push_all(src.as_slice())
    src.clear()
}

fn count_errors(diags: &List(Diagnostic)) usize {
    let n: usize = 0
    for i in 0..diags.len {
        if diags[i].severity == Severity.Error {
            n = n + 1
        }
    }
    return n
}

// ─────────────────────────────────────────────────────────────────────
// Multi-module project analysis
//
// `analyze_project` discovers the full module set by following imports from the entry sources (plus
// the auto-imported core prelude), resolving each against `ctx`, then type-checks every module
// together via one `check_all`. Each module's source is owned by the returned unit; the AST views
// into it (flang_parser/projector.f), so the sources outlive the modules.
// ─────────────────────────────────────────────────────────────────────

// A type-checked multi-module project. Parallel lists are keyed by file id (a module's index):
// `sources[i]` / `file_paths[i]` back `modules[i]`, whose registered FQN is `fqns[i]`.
pub type AnalyzedProject = struct {
    sources: List(OwnedString)
    fqns: List(OwnedString)
    file_paths: List(OwnedString)
    modules: List(Module)
    // Per module: was it one of the project's own files, as opposed to the stdlib or a dependency.
    // Kept because a re-check has to rebuild the checker with the same project boundary the first
    // one used.
    project_origin: List(bool)
    // Per module: whether this demand checked its bodies (RFC-022 §6 lazy demand). Empty when the
    // demand was total - every consumer may then treat every module as demanded. Lowering skips the
    // modules this leaves out: their bodies have no node types to lower, and nothing demanded can
    // reach them (identifier and operator resolution are import-scoped).
    demanded: List(bool)
    // Sources and ASTs that a re-parse replaced, held until the unit is dropped. A
    // `TypeCheckResult` holds string views into the source it was checked from (nominal FQNs, field
    // names) and AST pointers into the module, so a result outlives the buffers it was built over.
    retired_sources: List(OwnedString)
    retired_modules: List(Module)
    // Results a later demand replaced. A replayed body slot (RFC-022 5d) views an earlier result's
    // `synth_strings` buffers, so a retired result is slimmed (`slim_retire`) rather than freed:
    // the tables go, the viewed buffers stay until unit teardown. `keep_retired` keeps the tables
    // too, for a caller that copied `result` before re-demanding and reads the copy after (gate A).
    // Each entry is pushed after its type table was adopted by the next demand.
    retired_results: List(TypeCheckResult)
    keep_retired: bool
    result: TypeCheckResult
    checked: bool
    // Everything the parse tier produced: a module's own parse errors, plus the load failures that
    // have no module (an unreadable file, an unresolved global import). Held apart because
    // `diagnostics` is rebuilt on every check and the parse tier outlives the check that replays
    // it.
    parse_diags: List(Diagnostic)
    // The published list: `parse_diags` replayed, then the current check's.
    diagnostics: List(Diagnostic)
    // The checker every demand on this project runs through. It outlives one check so the declared
    // type names can: `begin_demand` keeps them and drops the rest, and `check_project` collects
    // only the modules that were re-parsed.
    checker: Checker
    // Template expansion output: the chunk modules whose decls were appended into `modules` (kept
    // alive here) and the per-origin generated text (`--emit-generated`). `sources`/`file_paths`
    // also hold one padded entry per chunk, after the real files.
    generated: TemplateOutput

    // Wall time of the front half, for `--timings`. `parse_ns` covers the import-graph walk (read +
    // lex + parse); `check_ns` covers template expansion, resolution and inference.
    parse_ns: u64
    check_ns: u64
}

// `overrides` supplies a buffer to use in place of the file on disk, for every path it names - an
// editor's unsaved text. `flang build` passes none. See `read_source` for the key convention.
pub fn analyze_project(ctx: &ResolveCtx, entries: &List(OwnedString), overrides: &Dict(String,
        String)? = null, allocator: &Allocator? = null) AnalyzedProject {
    let parse_diags: List(Diagnostic) = list(0, allocator)
    let sources: List(OwnedString) = list(0, allocator)
    let fqns: List(OwnedString) = list(0, allocator)
    let file_paths: List(OwnedString) = list(0, allocator)
    let modules: List(Module) = list(0, allocator)
    const parse_start = monotonic_ns()

    // BFS over the import graph, deduplicated by canonical file identity (`canon_path`) - the same
    // file reached under two spellings (relative vs absolute, `./`, drive-letter case) is one
    // module. The queue keeps each path as first spelled; the canonical form is only the identity.
    let queue: List(OwnedString) = list(0, allocator)
    let seen: Set(OwnedString) = set(allocator)
    for i in 0..entries.len {
        enqueue_copy(&queue, &seen, entries[i].as_view())
    }
    // Everything enqueued from here on is stdlib, a dependency or a transitive import - never a
    // project file. `[imports].global` applies to project files only, so the boundary has to be
    // recorded before the seeds run.
    let project_count = queue.len
    let project_origin: List(bool) = list(0, allocator)
    seed_globals(ctx, &queue, &seen, &parse_diags, allocator)
    seed_prelude(ctx, &queue, &seen, allocator)
    seed_stdlib(ctx, &queue, &seen, allocator)

    // Import edges as they resolve. `edge_to` holds paths, not indices: the target module may not
    // be parsed yet when the edge is seen.
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
            parse_diags.push(error("E0001", msg, none_span()))
            continue
        }
        let src = src_opt.unwrap()
        let fid = modules.len as i32
        let module = parse_to_module(src.as_view(), fid, &ctx.comptime, &parse_diags, allocator)
        let fqn = module_fqn(ctx, path, allocator)
        enqueue_imports(ctx, &module, modules.len, &queue, &seen, &edge_from, &edge_to,
            &parse_diags, allocator)
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
        demanded = list(0, allocator),
        retired_sources = list(0, allocator),
        retired_modules = list(0, allocator),
        retired_results = list(0, allocator),
        keep_retired = false,
        result = empty_result(allocator),
        checked = false,
        parse_diags = parse_diags,
        diagnostics = list(0, allocator),
        checker = checker(allocator),
        generated = empty_template_output(allocator),
        parse_ns = parse_ns,
        check_ns = 0,
    }
    const check_start = monotonic_ns()
    check_project(&unit, ctx, &edge_from, &edge_to, null, allocator)
    unit.check_ns = elapsed_ns(check_start)
    return unit
}

// Run the checker over the module set `self` already holds and install the result.
// `edge_from`/`edge_to` are the import graph, used to order the walk.
//
// Safe to call more than once on the same unit: expansion leaves one padded `sources`/`file_paths`
// entry per generated chunk, and those are trimmed off first so a second run starts from the state
// the first one saw, and the published diagnostics are rebuilt from `parse_diags` up.
fn check_project(self: &AnalyzedProject, ctx: &ResolveCtx, edge_from: &List(usize),
    edge_to: &List(OwnedString), recollect: &List(bool)?, allocator: &Allocator?) {
    // Expansion appends one source per generated chunk. Those buffers are retired, since a result
    // from a previous check holds string views into them; the matching `file_paths` entries are
    // freed, because `TypeCheckResult` keeps its own copies of paths.
    while self.sources.len > self.modules.len {
        const gone = self.sources.pop()
        if gone.is_some() {
            self.retired_sources.push(gone.unwrap())
        }
    }
    trim_owned(&self.file_paths, self.modules.len)

    // The check tier is regenerated whole on every demand, so the previous run's copy goes and the
    // parse tier is replayed underneath it.
    self.diagnostics.deinit()
    self.diagnostics = self.parse_diags.map(fn(d: Diagnostic) { clone_diag(&d) }, allocator)

    self.checked = count_errors(&self.diagnostics) == 0
    if !self.checked {
        return
    }

    let path_views = self.fqns.map(fn(s: OwnedString) { s.as_view() })
    defer path_views.deinit()
    let edges = index_edges(&self.file_paths, edge_from, edge_to, allocator)
    defer edges.deinit()
    let order = demand_order(path_views.len, &path_views, &edges, allocator)
    defer order.deinit()

    // Lazy demand: which modules' bodies this demand checks. Total (an empty mask) unless the
    // context asks for laziness - the LSP and the analysis tests want every body.
    self.demanded.deinit()
    self.demanded = if ctx.lazy_bodies {
        demand_mask(&path_views, &self.project_origin, &ctx.global_imports, &edges, allocator)
    } else {
        list(0, allocator)
    }
    let dm: &List(bool)? = null
    if self.demanded.len > 0 {
        dm = Some(&self.demanded)
    }

    let chk = &self.checker
    chk.begin_demand()
    // The type table is one per project: adopt it out of the previous result so the carried nominal
    // bodies' handles stay resolvable, and retire what is left of that result - a caller-held copy
    // (gate A) may still read its tables, so the storage lives until unit teardown. The previous
    // result's table sizes presize the demand's fresh tables, since a re-demand rewrites nearly
    // every entry.
    chk.adopt_interner(take_interner(&self.result))
    // The specialization registry carries the same way (RFC-022 5e): entries the demand can
    // validate are reused instead of re-checked, the rest re-instantiate at the ids they hold. A
    // gate-A caller still reads the previous result's tables after the re-demand, so it gets a deep
    // copy and the original stays.
    chk.adopt_specs(take_specs(&self.result, self.keep_retired))
    const sizes = table_caps(&self.result)
    chk.presize_results(&sizes)
    if !self.keep_retired {
        slim_retire(&self.result)
    }
    self.retired_results.push(self.result)
    let gens = template_state(allocator)
    chk.set_comptime_ctx(ctx.comptime)
    chk.set_project_globals(&ctx.global_imports, &self.project_origin)
    self.result = check_all(chk, &self.modules, &path_views, &self.sources, &self.file_paths, &gens,
        Some(&order), recollect, dm)
    drain_diagnostics(&self.diagnostics, &chk.diagnostics)
    self.generated = gens.take_output()
    gens.deinit()

    // W1003 unused functions, over the resolution edges the check just recorded. Opt-in per
    // context: a build's demand never checks `test {}` bodies, so `tests_checked` is false and
    // test-bearing modules are rooted conservatively. Only on a clean check: with errors present
    // the tables are partial and reachability would be noise on top of the real problem.
    if ctx.warn_unused and self.project_origin.len > 0 and count_errors(&self.diagnostics) == 0 {
        let w = unused_functions(&self.result, &self.modules, &path_views, &self.project_origin,
            ctx.lib_kind, false, allocator)
        drain_diagnostics(&self.diagnostics, &w)
        w.deinit()
        let wi = unused_imports(&self.result, &self.modules, &path_views, &self.project_origin,
            false, allocator)
        drain_diagnostics(&self.diagnostics, &wi)
        wi.deinit()
    }
}

// The demand set for a lazy check (RFC-022 §6): the project's own modules, the auto-imported
// prelude, the `[imports].global` modules, and everything transitively imported from any of them. A
// module outside the set can contribute nothing to a demanded body - identifiers, operators and
// constants resolve only through imports - so its bodies are never checked.
fn demand_mask(fqns: &List(String), project_origin: &List(bool), globals: &List(OwnedString),
    edges: &List(ImportEdge), alloc: &Allocator?) List(bool) {
    let mask = filled_list(fqns.len, false, alloc)
    let work: List(usize) = list(fqns.len, alloc)
    defer work.deinit()
    for i in 0..fqns.len {
        if !demand_root(fqns[i], i, project_origin, globals) {
            continue
        }
        mask[i] = true
        work.push(i)
    }

    let adj: List(List(usize)) = list(fqns.len, alloc)
    defer adj.deinit()
    for _i in 0..fqns.len {
        adj.push(list(0, alloc))
    }
    for &e in edges {
        if e.from < fqns.len and e.to < fqns.len {
            let row = &adj[e.from]
            row.push(e.to)
        }
    }

    let head: usize = 0
    while head < work.len {
        const m = work[head]
        head = head + 1
        for t in adj[m] {
            if !mask[t] {
                mask[t] = true
                work.push(t)
            }
        }
    }
    return mask
}

fn demand_root(fqn: String, i: usize, project_origin: &List(bool),
    globals: &List(OwnedString)) bool {
    if i < project_origin.len and project_origin[i] {
        return true
    }
    if fqn == "core.prelude" {
        return true
    }
    for &g in globals {
        if fqn == g.as_view() {
            return true
        }
    }
    return false
}

// Drop trailing entries until `xs` holds `n`, freeing each one.
fn trim_owned(xs: &List(OwnedString), n: usize) {
    while xs.len > n {
        const gone = xs.pop()
        if gone.is_some() {
            gone.unwrap().deinit()
        }
    }
}

// Check the project again, re-parsing only what is stale and reusing every other module's AST.
//
// A module is stale when the caller names it in `dirty`, or when template expansion appended
// generated declarations to it - those declarations live in the AST, so reusing one would stack a
// second copy on the next expansion. If the parse tier reported anything at all, everything is
// stale: its diagnostics are one flat list, so the ones belonging to modules that are still good
// cannot be told apart from the rest and all must be reproduced.
//
// The module SET is assumed unchanged - same files, same imports. Editing a module's imports is
// what would break that, and re-running `analyze_project` is the answer until the loader itself
// becomes incremental.
pub fn reanalyze(self: &AnalyzedProject, ctx: &ResolveCtx, dirty: &Set(String),
    overrides: &Dict(String, String)? = null, allocator: &Allocator? = null) {
    const reparse_all = self.parse_diags.len > 0
    if reparse_all {
        self.parse_diags.deinit()
        self.parse_diags = list(0, allocator)
    }
    let stale: Set(String) = set(allocator)
    defer stale.deinit()
    for &e in self.generated.emitted {
        stale.add(e.origin_path)
    }

    const parse_start = monotonic_ns()
    // Per module: was it re-parsed. A reused AST is the same declarations the checker already has
    // names for, so only the re-parsed ones are collected again. A module whose read failed keeps
    // the AST it had, and is left out for the same reason.
    let recollect = filled_list(self.modules.len, false, allocator)
    let srcs = &self.sources
    let mods = &self.modules
    for i in 0..self.modules.len {
        const path = self.file_paths[i].as_view()
        if !reparse_all and !dirty.contains(path) and !stale.contains(path) {
            continue
        }
        const fresh = read_source(path, overrides)
        if fresh.is_none() {
            const msg = $"cannot read source `{path}`"
            self.parse_diags.push(error("E0001", msg, none_span()))
            continue
        }
        self.retired_sources.push(srcs[i])
        self.retired_modules.push(mods[i])
        srcs[i] = fresh.unwrap()
        mods[i] = parse_to_module(srcs[i].as_view(), i as i32, &ctx.comptime, &self.parse_diags,
            allocator)
        recollect[i] = true
    }
    self.parse_ns = elapsed_ns(parse_start)

    // ponytail: re-walks the whole import graph, one `resolve_import` per import. Cache the edges
    // on the unit if a profile shows it.
    let edge_from = list(0, allocator)
    defer edge_from.deinit()
    let edge_to = list(0, allocator)
    defer edge_to.deinit()
    collect_edges(ctx, &self.modules, &edge_from, &edge_to, allocator)

    self.generated.deinit()
    self.generated = empty_template_output(allocator)

    const check_start = monotonic_ns()
    check_project(self, ctx, &edge_from, &edge_to, Some(&recollect), allocator)
    self.check_ns = elapsed_ns(check_start)
    recollect.deinit()
}

// Resolve every module's imports into `from -> to` edges. The BFS records these for free on a first
// analysis; a re-check has to ask again.
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
                }
                _ => {}
            }
        }
    }
}

// The multi-module analogue of `analyze` for in-memory sources: the given sources ARE the module
// set - no import discovery, no file IO. `fqns[i]` is both `srcs[i]`'s module FQN and its
// diagnostic label. Test support: lowering suites use it to place well-known modules (core.option,
// core.string) next to the module under test. Consumes `srcs`.
pub fn analyze_source_set(srcs: List(OwnedString), fqns: &List(String),
    allocator: &Allocator? = null) AnalyzedProject {
    let parse_diags: List(Diagnostic) = list(0, allocator)
    let owned_fqns: List(OwnedString) = list(fqns.len, allocator)
    let file_paths: List(OwnedString) = list(fqns.len, allocator)
    let modules: List(Module) = list(srcs.len, allocator)
    const host = host_ctx()
    for i in 0..srcs.len {
        modules.push(parse_to_module(srcs[i].as_view(), i as i32, &host, &parse_diags, allocator))
        owned_fqns.push(from_view(fqns[i]))
        file_paths.push(from_view(fqns[i]))
    }

    let diagnostics = parse_diags.map(fn(d: Diagnostic) { clone_diag(&d) }, allocator)
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
        demanded = list(0, allocator),
        retired_sources = list(0, allocator),
        retired_modules = list(0, allocator),
        retired_results = list(0, allocator),
        keep_retired = false,
        result = result,
        checked = checked,
        parse_diags = parse_diags,
        diagnostics = diagnostics,
        checker = checker(allocator),
        generated = generated,
        parse_ns = 0,
        check_ns = 0,
    }
}

pub fn deinit(self: &AnalyzedProject) {
    self.retired_results.deinit()
    self.retired_modules.deinit()
    self.retired_sources.deinit()
    self.demanded.deinit()
    self.project_origin.deinit()
    self.diagnostics.deinit()
    self.parse_diags.deinit()
    self.checker.deinit()
    self.generated.deinit()
    self.modules.deinit()
    self.fqns.deinit()
    self.file_paths.deinit()
    self.sources.deinit()
    self.result.deinit()
}

// Write each origin's generated text to `<origin>.generated.f` (`--emit-generated`). Debug output
// only - nothing ever reads it back
// (RFC-021 §4). Returns how many files were written.
pub fn write_generated(self: &AnalyzedProject) usize {
    let written: usize = 0
    for &e in self.generated.emitted {
        const path = generated_path(e.origin_path)
        defer path.deinit()
        let f = open_file(path.as_view(), FileMode.Write) match {
            Ok(f) => f
            Err(_) => continue
        }
        const w = f.write(e.text.as_view())
        const _c = close_file(&f)
        if w.is_ok() {
            written = written + 1
        }
    }
    return written
}

// Total error-severity diagnostics across every module.
pub fn project_error_count(self: &AnalyzedProject) usize {
    return count_errors(&self.diagnostics)
}

// Keep retired results whole instead of slimming them - for a caller that copies `result` before a
// re-demand and reads the copy's tables after (gate A).
pub fn keep_retired_results(self: &AnalyzedProject) {
    self.keep_retired = true
}

fn parse_to_module(src: String, file_id: i32, target: &ComptimeCtx, diags: &List(Diagnostic),
    alloc: &Allocator?) Module {
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

// Queue every module `m` imports, recording `from -> imported` so the checker can be given a
// dependency-respecting visit order. `enqueue_owned` consumes the resolved path, so the edge keeps
// its own copy.
fn enqueue_imports(ctx: &ResolveCtx, m: &Module, from: usize, queue: &List(OwnedString),
    seen: &Set(OwnedString), edge_from: &List(usize), edge_to: &List(OwnedString),
    diags: &List(Diagnostic), alloc: &Allocator?) {
    for d in m.decls {
        d match {
            Import(id) => {
                let r = resolve_import(ctx, &id.path, alloc)
                r match {
                    Some(p) => {
                        edge_from.push(from)
                        edge_to.push(from_view(p.as_view()))
                        enqueue_owned(queue, seen, p)
                    }
                    None => push_unresolved(diags, &id, alloc)
                }
            }
            _ => {}
        }
    }
}

// `flang.toml`'s `[imports].global`. Loading the module is only half the job - `build_visibility`
// is what actually puts it in each project file's scope; this side just guarantees it is in the
// module set to be found.
fn seed_globals(ctx: &ResolveCtx, queue: &List(OwnedString), seen: &Set(OwnedString),
    diags: &List(Diagnostic), alloc: &Allocator?) {
    for &g in ctx.global_imports {
        let segs = split(g.as_view(), '.')
        let r = resolve_import(ctx, &segs, alloc)
        segs.deinit()
        r match {
            Some(p) => enqueue_owned(queue, seen, p)
            None => {
                const msg = $"unresolved global import `{g.as_view()}` from flang.toml [imports].global"
                diags.push(error("E0001", msg, none_span()))
            }
        }
    }
}

fn seed_prelude(ctx: &ResolveCtx, queue: &List(OwnedString), seen: &Set(OwnedString),
    alloc: &Allocator?) {
    let segs: List(String) = list(2, alloc)
    segs.push("core")
    segs.push("prelude")
    let r = resolve_import(ctx, &segs, alloc)
    segs.deinit()
    r match {
        Some(p) => enqueue_owned(queue, seen, p)
        None => {}
    }
}

// The reference compiler compiles every program against the whole stdlib regardless of imports, and
// lenient type resolution in the checker relies on every stdlib nominal being registered - so the
// BFS seeds the full stdlib tree.
//
// A stdlib file whose dotted name the project or a dependency provides itself is NOT seeded: the
// project rule outranks the include rule in `resolve_import`, so those modules load from the
// project and the stdlib's copy would be a duplicate. This is what makes the stdlib's own `std`
// project analyzable against any `--stdlib-path`, including a different stdlib checkout. ponytail:
// typechecks all of std on every build; prune to the import closure once stdlib type visibility
// turns strict.
fn seed_stdlib(ctx: &ResolveCtx, queue: &List(OwnedString), seen: &Set(OwnedString),
    alloc: &Allocator?) {
    if ctx.stdlib_root.as_view().len == 0 {
        return
    }
    let pattern = $"{ctx.stdlib_root.as_view()}/**/*.f"
    let found = glob_sources(pattern.as_view(), alloc)
    pattern.deinit()
    for i in 0..found.len {
        let norm = normalize_sep(found[i].as_view(), alloc)
        if shadowed_by_project(ctx, norm.as_view(), alloc) {
            norm.deinit()
            continue
        }
        enqueue_owned(queue, seen, norm)
    }
    found.deinit()
}

// Whether the project or a dependency provides its own module for this stdlib file's dotted name -
// resolution would never pick the stdlib copy, so the loader must not either.
fn shadowed_by_project(ctx: &ResolveCtx, stdlib_file: String, alloc: &Allocator?) bool {
    const rel = module_rel(stdlib_file, ctx.stdlib_root.as_view())
    if rel.is_none() {
        return false
    }
    let segs = split(rel.unwrap(), '/')
    defer segs.deinit()
    const r = resolve_import(ctx, &segs, alloc)
    if r.is_none() {
        return false
    }
    const p = r.unwrap()
    const shadowed = p.as_view() != stdlib_file
    p.deinit()
    return shadowed
}

// `<root>/std/io/file.f` -> `std/io/file`, or null when the path is not under the root.
fn module_rel(path: String, root: String) String? {
    if root.len == 0 or !starts_with(path, root) or path.len <= root.len {
        return null
    }
    if path[root.len] != '/' {
        return null
    }
    const rel = path[(root.len + 1)..path.len]
    if !ends_with(rel, ".f") {
        return null
    }
    return Some(rel[0..(rel.len - 2)])
}

// The text to compile for `path`: a supplied buffer when one stands in for that file, the file on
// disk otherwise. Keys are the forward-slash paths the resolver produces (`resolver.normalize_sep`)
// - a caller that spells a key any other way misses silently and gets the stale file.
//
// The returned buffer is a copy: the AST views into whichever source the project owns, and an
// override's storage belongs to the caller.
fn read_source(path: String, overrides: &Dict(String, String)?) OwnedString? {
    if overrides.is_some() {
        let hit = overrides.unwrap().get(path)
        if hit.is_some() {
            return Some(from_view(hit.unwrap()))
        }
    }
    return read_text(path)
}

// Turn the path-keyed import edges into module-index pairs, matching by canonical identity - an
// import can resolve to a spelling other than the one the module loaded under. An edge naming a
// path that never became a module (an unreadable file) is dropped. Feeds both the visit order and
// the lazy demand mask.
fn index_edges(file_paths: &List(OwnedString), edge_from: &List(usize), edge_to: &List(OwnedString),
    alloc: &Allocator?) List(ImportEdge) {
    let index_of: Dict(OwnedString, usize) = dict(alloc)
    defer index_of.deinit()
    for i in 0..file_paths.len {
        const key = canon_path(file_paths[i].as_view(), alloc)
        index_of.set(key.as_view(), i)
        key.deinit()
    }
    let edges = list(edge_from.len, alloc)
    for i in 0..edge_from.len {
        const key = canon_path(edge_to[i].as_view(), alloc)
        const to = index_of.get(key.as_view())
        key.deinit()
        if to.is_none() {
            continue
        }
        edges.push(ImportEdge { from = edge_from[i], to = to.unwrap() })
    }
    return edges
}

fn enqueue_copy(queue: &List(OwnedString), seen: &Set(OwnedString), path: String) {
    if !mark_seen(seen, path) {
        return
    }
    queue.push(from_view(path))
}

fn enqueue_owned(queue: &List(OwnedString), seen: &Set(OwnedString), owned: OwnedString) {
    if !mark_seen(seen, owned.as_view()) {
        owned.deinit()
        return
    }
    queue.push(owned)
}

// Record `path`'s canonical identity; false when that file was already enqueued under any spelling.
fn mark_seen(seen: &Set(OwnedString), path: String) bool {
    const key = canon_path(path)
    defer key.deinit()
    if seen.contains(key.as_view()) {
        return false
    }
    seen.add(key.as_view())
    return true
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

test "one file reached under two spellings loads once" {
    let proj = parse_project("[project]\nname = \"p\"\nkind = \"exe\"\nsource = \"src/**/*.f\"\n")
    defer proj.deinit()
    let ctx = resolve_ctx(&proj, "")
    defer ctx.deinit()
    let entries: List(OwnedString) = list(2)
    defer entries.deinit()
    entries.push(from_view("src/main.f"))
    entries.push(from_view("./src/main.f"))
    let ov: Dict(String, String) = dict()
    defer ov.deinit()
    ov.set("src/main.f", "fn main() i32 { return 0 }\n")

    let unit = analyze_project(&ctx, &entries, Some(&ov))
    defer unit.deinit()
    assert_eq(unit.modules.len, 1 as usize, "the spellings dedup to one module")
    assert_eq(unit.diagnostics.len, 0 as usize, "and nothing is declared twice")
}

test "re-analysis republishes diagnostics rather than appending to them" {
    // One warning stays one warning across a re-demand of the same sources. An empty stdlib root
    // leaves `core.prelude` unresolved and `seed_stdlib` a no-op, so the module set is exactly what
    // the override supplies.
    let proj = parse_project("[project]\nname = \"p\"\nkind = \"exe\"\nsource = \"src/**/*.f\"\n")
    defer proj.deinit()
    let ctx = resolve_ctx(&proj, "")
    defer ctx.deinit()
    let entries: List(OwnedString) = list(1)
    defer entries.deinit()
    entries.push(from_view("src/main.f"))
    let ov: Dict(String, String) = dict()
    defer ov.deinit()
    ov.set("src/main.f",
        "fn main() i32 {\n    const v: i32 = 1\n    const v: i32 = 2\n    return v\n}\n")

    let unit = analyze_project(&ctx, &entries, Some(&ov))
    defer unit.deinit()
    assert_true(unit.checked, "the module type-checks")
    const cold = unit.diagnostics.len
    assert_eq(cold, 1 as usize, "one shadowing warning")

    let dirty: Set(String) = set()
    defer dirty.deinit()
    reanalyze(&unit, &ctx, &dirty, Some(&ov))
    assert_eq(unit.diagnostics.len, cold, "the same one warning, not two")
}

test "an edit adds, removes and leaves declarations alone" {
    // A declaration the edit does not touch answers to the id it already had, across an insertion
    // above it, a removal beside it, and a use of the removed name.
    let proj = parse_project("[project]\nname = \"p\"\nkind = \"exe\"\nsource = \"src/**/*.f\"\n")
    defer proj.deinit()
    let ctx = resolve_ctx(&proj, "")
    defer ctx.deinit()
    let entries: List(OwnedString) = list(1)
    defer entries.deinit()
    entries.push(from_view("src/main.f"))
    let ov: Dict(String, String) = dict()
    defer ov.deinit()
    const with_ab = "type A = struct { x: i32 }\ntype B = struct { y: i32 }\nfn main() i32 { return 0 }\n"
    ov.set("src/main.f", with_ab)

    let unit = analyze_project(&ctx, &entries, Some(&ov))
    defer unit.deinit()
    assert_eq(unit.diagnostics.len, 0 as usize, "two structs and a main type-check")
    const a0 = unit.result.nominals.lookup_fqn("p.main.A").unwrap()
    const b0 = unit.result.nominals.lookup_fqn("p.main.B").unwrap()

    let dirty: Set(String) = set()
    defer dirty.deinit()
    dirty.add("src/main.f")

    // Insert a declaration between the two existing ones.
    ov.set("src/main.f",
        "type A = struct { x: i32 }\ntype C = struct { z: i32 }\ntype B = struct { y: i32 }\nfn main() i32 { return 0 }\n")
    reanalyze(&unit, &ctx, &dirty, Some(&ov))
    assert_eq(unit.diagnostics.len, 0 as usize, "the added struct type-checks")
    const noms1 = &unit.result.nominals
    assert_eq(noms1.lookup_fqn("p.main.A").unwrap(), a0,
        "the declaration above the insertion keeps its id")
    assert_eq(noms1.lookup_fqn("p.main.B").unwrap(), b0, "and so does the one below it")
    const c1 = noms1.lookup_fqn("p.main.C")
    assert_true(c1.is_some(), "the added declaration is registered")
    assert_true(c1.unwrap() != a0 and c1.unwrap() != b0, "under an id of its own")

    // Remove one, keeping the other two.
    ov.set("src/main.f",
        "type A = struct { x: i32 }\ntype C = struct { z: i32 }\nfn main() i32 { return 0 }\n")
    reanalyze(&unit, &ctx, &dirty, Some(&ov))
    assert_eq(unit.diagnostics.len, 0 as usize, "removing an unused struct type-checks")
    const noms2 = &unit.result.nominals
    assert_true(noms2.lookup_fqn("p.main.B").is_none(), "the removed declaration stops resolving")
    assert_eq(noms2.lookup_fqn("p.main.A").unwrap(), a0, "the survivors keep the ids they had")
    assert_eq(noms2.lookup_fqn("p.main.C").unwrap(), c1.unwrap(),
        "including the one added a demand ago")

    // And a use of the removed declaration is an error, not a stale hit.
    ov.set("src/main.f", "type A = struct { x: i32 }\nfn main() B { return 0 }\n")
    reanalyze(&unit, &ctx, &dirty, Some(&ov))
    assert_true(unit.diagnostics.len > 0, "naming a removed type is reported")
}

test "the demand mask is the project's import closure plus prelude and globals" {
    // 0 = the project file, 1 = its import, 2 = 1's import, 3 = an unimported stdlib module that
    // itself imports 1, 4 = the auto-imported prelude, 5 = a [imports].global module.
    let fqns: List(String) = list(6)
    defer fqns.deinit()
    fqns.push("p.main")
    fqns.push("std.a")
    fqns.push("std.b")
    fqns.push("std.c")
    fqns.push("core.prelude")
    fqns.push("std.g")
    let origin: List(bool) = list(6)
    defer origin.deinit()
    origin.push(true)
    for _i in 0usize..5usize {
        origin.push(false)
    }
    let globals: List(OwnedString) = list(1)
    defer globals.deinit()
    globals.push(from_view("std.g"))
    let edges: List(ImportEdge) = list(3)
    defer edges.deinit()
    edges.push(ImportEdge { from = 0, to = 1 })
    edges.push(ImportEdge { from = 1, to = 2 })
    edges.push(ImportEdge { from = 3, to = 1 })

    let mask = demand_mask(&fqns, &origin, &globals, &edges, null)
    defer mask.deinit()
    assert_true(mask[0], "the project file is a root")
    assert_true(mask[1], "its import is demanded")
    assert_true(mask[2], "transitively")
    assert_true(!mask[3], "importing a demanded module does not make the importer demanded")
    assert_true(mask[4], "the prelude is auto-imported everywhere")
    assert_true(mask[5], "a global import is in every project file's scope")
}

test "a path no override names falls through to the file on disk" {
    let ov: Dict(String, String) = dict()
    defer ov.deinit()
    ov.set("other.f", "fn other() i32 { return 1 }\n")
    assert_true(read_source("no/such/file.f", Some(&ov)).is_none(),
        "an unnamed path reads from disk, and misses")
    assert_true(read_source("no/such/file.f", null).is_none(), "so does no override map at all")
}
