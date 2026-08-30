// W1003 - unused project functions.
//
// Reachability over the resolution edges the checker records: `resolved_targets` (`RtFunction` /
// `RtSpecialized`), `ResolvedOperator.function_id`, receiver-deref chains, and each
// specialization's overlay tables. Dispatch is recorded rather than name-matched, so protocol calls
// (`op_eq` from a `==`, `iter`/`next` from a for-loop, operator overloads, defaulted-argument
// expressions) never count as unused.
//
// Scope is the current project's own modules. Roots:
//
//   - `main`, always
//   - every `pub fn` when the project is a library (they are its API)
//   - a use outside any function body - a constant initializer, a default value at module scope
//
// An executable's `pub fn` is NOT a root: every function must be reachable from `main`.
//
// Blind spots, both conservative (a missed warning, never a false one):
//
//   - `test {}` bodies are not checked by a build, so their calls record no edges. Any module that
//     contains a test block roots its own non-`pub` functions - they may exist only for its tests.
//   - A site whose span cannot be placed inside a project function (checker-synthesized AST,
//     generated declarations) roots its target instead of edging to it.
//
// Overloads are per-declaration: one overload used does not excuse its siblings. A `_`-prefixed
// name suppresses the warning, matching W1001.

import std.allocator
import std.dict
import std.list
import std.option
import std.set
import std.string
import std.string_builder
import std.test
import std.io.fs
import flang_core.diagnostic
import flang_core.span
import flang_parser.ast
import flang_typer.type
import flang_typer.node_id
import flang_typer.error_codes
import flang_typer.interner
import flang_typer.inference_results
import flang_typer.function_registry
import flang_typer.nominal_registry
import flang_typer.specialization
import flang_typer.result
import flang_analysis.project
import flang_analysis.resolver
import flang_analysis.analyze

// One project function under consideration: its registry id, where it is declared, and the flags
// the root rules read.
type FnNode = struct {
    id: u32
    name: String
    is_pub: bool
    file: usize
    start: usize
    end: usize
}

// The W1003 diagnostics for one checked project, sorted by (file, start). `fqns[i]` is module `i`'s
// FQN - the name the registry's schemes carry - and `project_origin[i]` marks the project's own
// files. `lib_kind` selects the library root rule. `tests_checked` says whether the demand that
// produced `result` checked `test {}` bodies: when it did (the LSP), test use is in the recorded
// edges and needs no allowance; when it did not (a build), every non-`pub` function of a
// test-bearing module is rooted conservatively.
pub fn unused_functions(result: &TypeCheckResult, modules: &List(Module), fqns: &List(String),
    project_origin: &List(bool), lib_kind: bool, tests_checked: bool,
    allocator: &Allocator? = null) List(Diagnostic) {
    // Project module FQN -> its index (= its file id).
    let index_of: Dict(String, usize) = dict(allocator)
    defer index_of.deinit()
    for i in 0..fqns.len {
        if i < project_origin.len and project_origin[i] {
            index_of.set(fqns[i], i)
        }
    }

    let has_tests = filled_list(modules.len, false, allocator)
    defer has_tests.deinit()
    for i in 0..modules.len {
        for &d in modules[i].decls {
            d.* match {
                Test(_) => { has_tests[i] = true }
                _ => {}
            }
        }
    }

    // Every project function, keyed by registry id, plus a per-file list sorted by start offset for
    // span containment. Foreign declarations have no body and are left out entirely; a generated
    // declaration's span cites its chunk's file id, not its origin module's, and is left out the
    // same way.
    let nodes: Dict(u32, FnNode) = dict(allocator)
    defer nodes.deinit()
    let per_file: List(List(FnNode)) = list(modules.len, allocator)
    defer per_file.deinit()
    for _i in 0..modules.len {
        per_file.push(list(0, allocator))
    }
    let reached: Dict(u32, bool) = dict(allocator)
    defer reached.deinit()
    let work: List(u32) = list(0, allocator)
    defer work.deinit()

    for entry in result.functions.by_name {
        const overloads = entry.value
        for j in 0..overloads.len {
            const f = &overloads[j]
            if f.retired or f.is_foreign {
                continue
            }
            const m = f.module
            if m.is_none() {
                continue
            }
            const idx_opt = index_of.get(m.unwrap())
            if idx_opt.is_none() {
                continue
            }
            const idx = idx_opt.unwrap()
            if f.decl_span.file_id < 0 or (f.decl_span.file_id as usize) != idx {
                continue
            }
            const node = FnNode {
                id = f.id,
                name = f.name,
                is_pub = f.is_pub,
                file = idx,
                start = f.decl_span.start,
                end = f.decl_span.start + f.decl_span.length,
            }
            nodes.set(f.id, node)
            let row = &per_file[idx]
            row.push(node)
            if is_root(&node, lib_kind, tests_checked, &has_tests) {
                mark(&reached, &work, f.id)
            }
        }
    }
    for &row in per_file {
        row.sort(cmp_start)
    }

    // Edges. A target outside the project is dropped; a site outside any project function roots its
    // target.
    let adj: Dict(u32, List(u32)) = dict(allocator)
    defer adj.deinit()
    add_table_edges(result, &result.resolved_targets, &result.resolved_ops, &result.receiver_derefs,
        &nodes, &per_file, &adj, &reached, &work, allocator)
    add_overlay_edges(result, &nodes, &adj, &reached, &work, allocator)

    // Reachability.
    let head: usize = 0
    while head < work.len {
        const from = work[head]
        head = head + 1
        const out = adj.get_ref(from)
        if out.is_none() {
            continue
        }
        for t in out.unwrap() {
            mark(&reached, &work, t)
        }
    }

    // Report the unreached, source order per file.
    let missed: List(FnNode) = list(0, allocator)
    defer missed.deinit()
    for entry in nodes {
        const n = entry.value
        if reached.get(n.id).is_some() {
            continue
        }
        if n.name.len > 0 and n.name[0] == '_' {
            continue
        }
        missed.push(n)
    }
    missed.sort(cmp_file_start)

    let out: List(Diagnostic) = list(missed.len, allocator)
    for &n in missed {
        out.push(Diagnostic {
            severity = Severity.Warning,
            code = W_UNUSED_FUNCTION,
            message = $"unused function `{n.name}`",
            hint = from_view("prefix with `_` to suppress"),
            span = SourceSpan { file_id = n.file as i32, start = n.start,
                length = n.end - n.start },
        })
    }
    return out
}

fn is_root(n: &FnNode, lib_kind: bool, tests_checked: bool, has_tests: &List(bool)) bool {
    if n.name == "main" {
        return true
    }
    if lib_kind and n.is_pub {
        return true
    }
    // When test bodies were not checked, a module with test blocks may use any of its own non-`pub`
    // functions invisibly - a demand that checked them has their use in the edges instead.
    if !tests_checked and n.file < has_tests.len and has_tests[n.file] and !n.is_pub {
        return true
    }
    return false
}

fn mark(reached: &Dict(u32, bool), work: &List(u32), id: u32) {
    if reached.get(id).is_some() {
        return
    }
    reached.set(id, true)
    work.push(id)
}

// The project function id a resolved target names, if any.
fn target_fn(result: &TypeCheckResult, t: &ResolvedTarget) u32? {
    return t.* match {
        RtFunction(fid) => Some(fid)
        RtSpecialized(sid) => result.specializations.find(sid) match {
            Some(s) => Some(s.function_id)
            None => null
        }
        _ => null
    }
}

// Record `from-site -> fid`: an edge from the enclosing project function, or a root when the site
// has no such home.
fn add_site(key: NodeId, fid: u32, result: &TypeCheckResult, nodes: &Dict(u32, FnNode),
    per_file: &List(List(FnNode)), adj: &Dict(u32, List(u32)), reached: &Dict(u32, bool),
    work: &List(u32), allocator: &Allocator?) {
    if nodes.get(fid).is_none() {
        return
    }
    const span = result.spans.get(key)
    let enc: u32? = null
    if span.is_some() {
        enc = enclosing_fn(per_file, span.unwrap())
    }
    enc match {
        Some(from) => {
            if adj.get_ref(from).is_none() {
                let fresh: List(u32) = list(1, allocator)
                adj.set(from, fresh)
            }
            let row = adj.get_ref(from).unwrap()
            row.push(fid)
        }
        None => mark(reached, work, fid)
    }
}

fn add_table_edges(result: &TypeCheckResult, targets: &Dict(NodeId, ResolvedTarget),
    ops: &Dict(NodeId, ResolvedOperator), derefs: &Dict(NodeId, List(ResolvedTarget)),
    nodes: &Dict(u32, FnNode), per_file: &List(List(FnNode)), adj: &Dict(u32, List(u32)),
    reached: &Dict(u32, bool), work: &List(u32), allocator: &Allocator?) {
    for e in targets {
        const t = e.value
        const fid = target_fn(result, &t)
        if fid.is_some() {
            add_site(e.key, fid.unwrap(), result, nodes, per_file, adj, reached, work, allocator)
        }
    }
    for e in ops {
        add_site(e.key, e.value.function_id, result, nodes, per_file, adj, reached, work, allocator)
    }
    for e in derefs {
        for &t in e.value {
            const fid = target_fn(result, t)
            if fid.is_some() {
                add_site(e.key, fid.unwrap(), result, nodes, per_file, adj, reached, work,
                    allocator)
            }
        }
    }
}

// A specialization's body edges live in its private overlay. They all attribute to the template
// function - which instantiation resolved them does not matter for reachability.
fn add_overlay_edges(result: &TypeCheckResult, nodes: &Dict(u32, FnNode), adj: &Dict(u32,
        List(u32)), reached: &Dict(u32, bool), work: &List(u32), allocator: &Allocator?) {
    for i in 0..(result.specializations.next_id as usize) {
        const found = result.specializations.find(i as SpecId)
        if found.is_none() {
            continue
        }
        const s = found.unwrap()
        if nodes.get(s.function_id).is_none() {
            continue
        }
        if adj.get_ref(s.function_id).is_none() {
            let fresh: List(u32) = list(4, allocator)
            adj.set(s.function_id, fresh)
        }
        let row = adj.get_ref(s.function_id).unwrap()
        for e in s.overlay.resolved_targets {
            const t = e.value
            const fid = target_fn(result, &t)
            if fid.is_some() and nodes.get(fid.unwrap()).is_some() {
                row.push(fid.unwrap())
            }
        }
        for e in s.overlay.resolved_ops {
            if nodes.get(e.value.function_id).is_some() {
                row.push(e.value.function_id)
            }
        }
        for e in s.overlay.receiver_derefs {
            for &t in e.value {
                const fid = target_fn(result, t)
                if fid.is_some() and nodes.get(fid.unwrap()).is_some() {
                    row.push(fid.unwrap())
                }
            }
        }
    }
}

// The project function whose declaration span contains `span`, if any. Function declarations in one
// file never overlap, so the last one starting at or before the site is the only candidate.
fn enclosing_fn(per_file: &List(List(FnNode)), span: SourceSpan) u32? {
    if span.file_id < 0 {
        return null
    }
    const f = span.file_id as usize
    if f >= per_file.len {
        return null
    }
    const fns = &per_file[f]
    // Binary search: last node with start <= span.start.
    let lo: usize = 0
    let hi: usize = fns.len
    while lo < hi {
        const mid = (lo + hi) / 2
        if fns[mid].start <= span.start {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    if lo == 0 {
        return null
    }
    const cand = &fns[lo - 1]
    if span.start < cand.end {
        return Some(cand.id)
    }
    return null
}

fn cmp_start(a: FnNode, b: FnNode) Ord {
    return op_cmp(a.start, b.start)
}

fn cmp_file_start(a: FnNode, b: FnNode) Ord {
    if a.file != b.file {
        return op_cmp(a.file, b.file)
    }
    return op_cmp(a.start, b.start)
}

// ─────────────────────────────────────────────────────────────────────
// W1004 - unused imports.
//
// The same evidence as W1003, aggregated per importing file: every recorded resolution edge (call
// targets, operator picks, deref chains, specialization overlays) plus every module whose nominal
// types a file's node types cite. An `import M` in file A warns when no edge from A lands in M or
// in anything M re-exports through `pub import`.
//
// Type citations count as uses even though type-name resolution is currently lenient
// (import-agnostic): import-strict types are a planned tightening, and counting them can only
// suppress a warning, never invent one.
//
// Conservative skips, same rationale as W1003 - a build's edges are incomplete exactly here:
//
//   - a module with `test {}` blocks keeps all its imports when test bodies were not checked
//   - a module that declares or invokes source generators is unattributable (generated code lands
//     in chunk files) and keeps its imports
//   - an import of a module that exports type aliases is kept - alias expansion leaves no trace
//     when the target is not a nominal
//   - `pub import` never warns; re-export is its purpose
// ─────────────────────────────────────────────────────────────────────

// The W1004 diagnostics for one checked project, sorted by (file, start). Parameters as
// `unused_functions`.
pub fn unused_imports(result: &TypeCheckResult, modules: &List(Module), fqns: &List(String),
    project_origin: &List(bool), tests_checked: bool,
    allocator: &Allocator? = null) List(Diagnostic) {
    // Module FQN -> index, all modules - uses land anywhere in the tree.
    let index_of: Dict(String, usize) = dict(allocator)
    defer index_of.deinit()
    for i in 0..fqns.len {
        index_of.set(fqns[i], i)
    }

    // Function id -> defining module FQN, for every registered function.
    let fn_module: Dict(u32, String) = dict(allocator)
    defer fn_module.deinit()
    for entry in result.functions.by_name {
        const overloads = entry.value
        for j in 0..overloads.len {
            if overloads[j].module.is_some() {
                fn_module.set(overloads[j].id, overloads[j].module.unwrap())
            }
        }
    }

    // Per project file: the set of module FQNs its recorded edges land in.
    let used: List(Set(String)) = list(modules.len, allocator)
    defer used.deinit()
    for _i in 0..modules.len {
        used.push(set(allocator))
    }

    for e in result.resolved_targets {
        const t = e.value
        note_use(e.key, target_module(result, &fn_module, &t), result, project_origin, &used)
    }
    for e in result.resolved_ops {
        note_use(e.key, fn_module.get(e.value.function_id), result, project_origin, &used)
    }
    for e in result.receiver_derefs {
        for &t in e.value {
            note_use(e.key, target_module(result, &fn_module, t), result, project_origin, &used)
        }
    }

    // An interpolation desugars to StringBuilder calls on synthesized nodes whose spans name no
    // file, so their resolutions cannot be attributed above. The desugar table is keyed by the
    // replaced node - a real span - and the desugar depends on `std.string_builder` by design
    // (RFC-004), so each entry pins that import for its file.
    for e in result.desugars {
        note_use(e.key, Some("std.string_builder"), result, project_origin, &used)
    }

    // Nominal citations in each project file's node types, tree-walked through the interner with a
    // per-file memo (types are heavily shared). One bucketing pass over the table, then one walk
    // per file.
    let buckets: List(List(Ty)) = list(modules.len, allocator)
    defer buckets.deinit()
    for _i in 0..modules.len {
        buckets.push(list(0, allocator))
    }
    for e in result.node_types {
        const span = result.spans.get(e.key)
        if span.is_none() or span.unwrap().file_id < 0 {
            continue
        }
        const f = span.unwrap().file_id as usize
        if f < modules.len and is_project(project_origin, f) {
            let b = &buckets[f]
            b.push(e.value)
        }
    }
    // One memo per file: the memo records "already walked for this file's set", so it cannot be
    // shared across files.
    let memos: List(Dict(Ty, bool)) = list(modules.len, allocator)
    defer memos.deinit()
    for _i in 0..modules.len {
        let m: Dict(Ty, bool) = dict(allocator)
        memos.push(m)
    }
    for i in 0..modules.len {
        for t in buckets[i] {
            add_ty_modules(result, t, &used[i], &memos[i])
        }
    }

    // Declarations cite types the node-type table never sees: a struct field's or enum payload's
    // type, and a function signature's parameter and return types (a `#foreign` or unreachable
    // function's body is never checked, so nothing else records them). The registries hold the
    // resolved types - walk each project declaration's.
    for entry in result.functions.by_name {
        const overloads = entry.value
        for j in 0..overloads.len {
            const f = &overloads[j]
            if f.retired or f.module.is_none() {
                continue
            }
            const home = index_of.get(f.module.unwrap())
            if home.is_some() and is_project(project_origin, home.unwrap()) {
                add_ty_modules(result, f.signature.body, &used[home.unwrap()],
                    &memos[home.unwrap()])
            }
        }
    }
    for i in 0..(result.nominals.next_id as usize) {
        const found = result.nominals.find(i as NominalId)
        if found.is_none() {
            continue
        }
        const def = found.unwrap()
        const home = index_of.get(nominal_module(def))
        if home.is_none() or !is_project(project_origin, home.unwrap()) {
            continue
        }
        let u = &used[home.unwrap()]
        let fmemo = &memos[home.unwrap()]
        def.* match {
            NomStruct(sd) => {
                for &fld in sd.fields {
                    add_ty_modules(result, fld.ty, u, fmemo)
                }
            }
            NomEnum(ed) => {
                for &v in ed.variants {
                    for p in v.payloads {
                        add_ty_modules(result, p, u, fmemo)
                    }
                }
            }
        }
    }

    // A specialization's overlay belongs wholesale to its template's module.
    for i in 0..(result.specializations.next_id as usize) {
        const found = result.specializations.find(i as SpecId)
        if found.is_none() {
            continue
        }
        const s = found.unwrap()
        const home = index_of.get(s.module)
        if home.is_none() or !is_project(project_origin, home.unwrap()) {
            continue
        }
        let u = &used[home.unwrap()]
        for e in s.overlay.resolved_targets {
            const t = e.value
            add_opt(u, target_module(result, &fn_module, &t))
        }
        for e in s.overlay.resolved_ops {
            add_opt(u, fn_module.get(e.value.function_id))
        }
        for e in s.overlay.receiver_derefs {
            for &t in e.value {
                add_opt(u, target_module(result, &fn_module, t))
            }
        }
        let smemo: Dict(Ty, bool) = dict(allocator)
        defer smemo.deinit()
        for e in s.overlay.node_types {
            add_ty_modules(result, e.value, u, &smemo)
        }
    }

    // Per module: its `pub import` targets, for the re-export closure.
    let reexports: List(List(usize)) = list(modules.len, allocator)
    defer reexports.deinit()
    for i in 0..modules.len {
        let row: List(usize) = list(0, allocator)
        for &d in modules[i].decls {
            d.* match {
                Import(id) => {
                    if id.is_pub {
                        let dotted = dotted_name(&id.path, allocator)
                        const to = index_of.get(dotted.as_view())
                        dotted.deinit()
                        if to.is_some() {
                            row.push(to.unwrap())
                        }
                    }
                }
                _ => {}
            }
        }
        reexports.push(row)
    }

    let missed: List(ImportSite) = list(0, allocator)
    defer missed.deinit()
    for i in 0..modules.len {
        if !is_project(project_origin, i) {
            continue
        }
        if !imports_attributable(&modules[i], i, tests_checked) {
            continue
        }
        for &d in modules[i].decls {
            d.* match {
                Import(id) => check_import(&id, i, fqns, &index_of, modules, &used[i], &reexports,
                    &missed, allocator)
                _ => {}
            }
        }
    }
    missed.sort(cmp_site)

    let out: List(Diagnostic) = list(missed.len, allocator)
    for &m in missed {
        out.push(Diagnostic {
            severity = Severity.Warning,
            code = W_UNUSED_IMPORT,
            message = $"unused import `{m.name.as_view()}`",
            hint = from_view("nothing from it is used - remove the import"),
            span = m.span,
        })
    }
    return out
}

type ImportSite = struct {
    name: OwnedString
    span: SourceSpan
}

pub fn deinit(self: &ImportSite) {
    self.name.deinit()
}

fn is_project(project_origin: &List(bool), i: usize) bool {
    return i < project_origin.len and project_origin[i]
}

// Whether file `i`'s import uses are fully visible in the recorded edges: no unchecked test bodies,
// and no source generators (their expansions record against chunk file ids).
fn imports_attributable(m: &Module, i: usize, tests_checked: bool) bool {
    for &d in m.decls {
        d.* match {
            Test(_) => {
                if !tests_checked {
                    return false
                }
            }
            GenDef(_) => return false
            GenInvoke(_) => return false
            _ => {}
        }
    }
    return true
}

// One import declaration's verdict. Skips - besides a resolved use - are `pub import`, the
// auto-imported prelude, a self-import, an import that never resolved (the loader reported it), and
// a target that exports what the edges cannot see (type aliases, generators).
fn check_import(id: &ImportDecl, from: usize, fqns: &List(String), index_of: &Dict(String, usize),
    modules: &List(Module), used: &Set(String), reexports: &List(List(usize)),
    missed: &List(ImportSite), allocator: &Allocator?) {
    if id.is_pub {
        return
    }
    // A generated declaration's import cites its chunk, not this file.
    if id.span.file_id != from as i32 {
        return
    }
    let dotted = dotted_name(&id.path, allocator)
    if dotted.as_view() == "core.prelude" or index_of.get(dotted.as_view()).is_none() {
        dotted.deinit()
        return
    }
    const target = index_of.get(dotted.as_view()).unwrap()
    if target == from {
        dotted.deinit()
        return
    }

    // The import's reach: the target plus its transitive `pub import`s. Used if any member is.
    let closure: List(usize) = list(4, allocator)
    defer closure.deinit()
    closure.push(target)
    let head: usize = 0
    while head < closure.len {
        const m = closure[head]
        head = head + 1
        for r in reexports[m] {
            if !contains_index(&closure, r) {
                closure.push(r)
            }
        }
    }
    for m in closure {
        if used.contains(fqns[m]) or exports_invisibles(&modules[m]) {
            dotted.deinit()
            return
        }
    }

    missed.push(ImportSite { name = dotted, span = id.span })
}

// Whether a module exports anything the recorded edges cannot witness: a `pub` type alias (its
// expansion leaves no trace when the target is not a nominal) or a source generator.
fn exports_invisibles(m: &Module) bool {
    for &d in m.decls {
        d.* match {
            GenDef(_) => return true
            Type(td) => {
                if td.is_pub and is_alias_body(td.body) {
                    return true
                }
            }
            _ => {}
        }
    }
    return false
}

fn is_alias_body(t: &TypeExpr) bool {
    return t.* match {
        AnonStruct(_) => false
        AnonEnum(_) => false
        _ => true
    }
}

// Note module `m` as used from the project file the site at `key` lies in.
fn note_use(key: NodeId, m: String?, result: &TypeCheckResult, project_origin: &List(bool),
    used: &List(Set(String))) {
    if m.is_none() {
        return
    }
    const span = result.spans.get(key)
    if span.is_none() or span.unwrap().file_id < 0 {
        return
    }
    const f = span.unwrap().file_id as usize
    if f >= used.len or !is_project(project_origin, f) {
        return
    }
    let u = &used[f]
    u.add(m.unwrap())
}

fn add_opt(u: &Set(String), m: String?) {
    if m.is_some() {
        u.add(m.unwrap())
    }
}

// The defining module of whatever a resolved target names, if it has one.
fn target_module(result: &TypeCheckResult, fn_module: &Dict(u32, String),
    t: &ResolvedTarget) String? {
    return t.* match {
        RtFunction(fid) => fn_module.get(fid)
        RtSpecialized(sid) => result.specializations.find(sid) match {
            Some(s) => Some(s.module)
            None => null
        }
        RtStructField(nid, _) => nominal_home(result, nid)
        RtEnumVariant(nid, _) => nominal_home(result, nid)
        RtConst(fqn) => const_module(fqn)
        _ => null
    }
}

fn nominal_home(result: &TypeCheckResult, nid: NominalId) String? {
    return result.nominals.find(nid) match {
        Some(def) => Some(nominal_module(def))
        None => null
    }
}

// `module.name` -> `module`. A constant's RtConst target carries its FQN.
fn const_module(fqn: String) String? {
    return rfind(fqn, '.') match {
        Some(dot) => Some(fqn[0..dot])
        None => null
    }
}

// Every module whose nominal types `t`'s tree cites, added to `used`. Memoised per handle - the
// tree is a DAG of shared interned nodes.
fn add_ty_modules(result: &TypeCheckResult, t: Ty, used: &Set(String), memo: &Dict(Ty, bool)) {
    if memo.get(t).is_some() {
        return
    }
    memo.set(t, true)
    const it = &result.interner
    it.node(t) match {
        NRef(inner) => add_ty_modules(result, inner, used, memo)
        NArray(a) => add_ty_modules(result, a.elem, used, memo)
        NFunc(f) => {
            for i in 0..f.params.len {
                add_ty_modules(result, it.child_at(f.params, i), used, memo)
            }
            add_ty_modules(result, f.ret, used, memo)
        }
        NTuple(span) => {
            for i in 0..span.len {
                add_ty_modules(result, it.child_at(span, i), used, memo)
            }
        }
        NRecord(r) => {
            for i in 0..r.tys.len {
                add_ty_modules(result, it.child_at(r.tys, i), used, memo)
            }
        }
        NNominal(n) => {
            add_opt(used, nominal_home(result, n.id))
            for i in 0..n.args.len {
                add_ty_modules(result, it.child_at(n.args, i), used, memo)
            }
        }
        _ => {}
    }
}

fn dotted_name(segs: &List(String), allocator: &Allocator?) OwnedString {
    let sb = string_builder(0, allocator)
    defer sb.deinit()
    for i in 0..segs.len {
        if i > 0 {
            sb.append('.')
        }
        sb.append(segs[i])
    }
    return sb.to_string()
}

fn contains_index(xs: &List(usize), v: usize) bool {
    for x in xs {
        if x == v {
            return true
        }
    }
    return false
}

fn cmp_site(a: ImportSite, b: ImportSite) Ord {
    if a.span.file_id != b.span.file_id {
        return op_cmp(a.span.file_id, b.span.file_id)
    }
    return op_cmp(a.span.start, b.span.start)
}

// Tests
//
// Each test analyses a one-file project through an override map (no stdlib, no disk), so the W1003
// pass runs exactly as a build runs it.

fn analyzed(source: String, manifest: String) AnalyzedProject {
    let proj = parse_project(manifest)
    defer proj.deinit()
    let ctx = resolve_ctx(&proj, "")
    defer ctx.deinit()
    ctx.set_warn_unused(true)
    let entries: List(OwnedString) = list(1)
    defer entries.deinit()
    entries.push(from_view("src/main.f"))
    let ov: Dict(String, String) = dict()
    defer ov.deinit()
    ov.set("src/main.f", source)
    return analyze_project(&ctx, &entries, Some(&ov))
}

fn exe_unit(source: String) AnalyzedProject {
    return analyzed(source, "[project]\nname = \"p\"\nkind = \"exe\"\nsource = \"src/**/*.f\"\n")
}

fn lib_unit(source: String) AnalyzedProject {
    return analyzed(source, "[project]\nname = \"p\"\nkind = \"lib\"\nsource = \"src/**/*.f\"\n")
}

// A project whose `import p.leaf` resolves to the committed fixture module (fixtures/leaf.f), for
// the W1004 tests - an import has to resolve to a real file to warrant a verdict, and the fixture
// keeps the module set two files small (no stdlib on disk). The source root is probed because
// `flang test` runs are launched from the repo root or from this library's directory.
fn analyzed_fixture(source: String) AnalyzedProject {
    const root = if exists("fixtures/leaf.f") { "fixtures" } else { "lib/flang_analysis/fixtures" }
    const manifest = $"[project]\nname = \"p\"\nkind = \"exe\"\nsource = \"{root}/**/*.f\"\n"
    defer manifest.deinit()
    let proj = parse_project(manifest.as_view())
    defer proj.deinit()
    let ctx = resolve_ctx(&proj, "")
    defer ctx.deinit()
    ctx.set_warn_unused(true)
    let entries: List(OwnedString) = list(1)
    defer entries.deinit()
    entries.push(from_view("main.f"))
    let ov: Dict(String, String) = dict()
    defer ov.deinit()
    ov.set("main.f", source)
    return analyze_project(&ctx, &entries, Some(&ov))
}

fn diag_messages(unit: &AnalyzedProject, code: String) List(String) {
    let out: List(String) = list(0)
    for i in 0..unit.diagnostics.len {
        if unit.diagnostics[i].code == code {
            out.push(unit.diagnostics[i].message.as_view())
        }
    }
    return out
}

test "an unreachable function warns and a called one does not" {
    let unit = exe_unit("fn used() i32 { return 1 }\nfn dead() i32 { return 2 }\nfn main() i32 { return used() }\n")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1003")
    defer w.deinit()
    assert_eq(w.len, 1 as usize, "exactly the dead function warns")
    assert_true(contains(w[0], "dead"), "and it is the dead one")
}

test "a `_`-prefixed function suppresses the warning" {
    let unit = exe_unit("fn _scratch() i32 { return 2 }\nfn main() i32 { return 0 }\n")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1003")
    defer w.deinit()
    assert_eq(w.len, 0 as usize, "the underscore opts out")
}

test "a library's pub functions are roots, its private dead code still warns" {
    let unit = lib_unit("pub fn api() i32 { return inner() }\nfn inner() i32 { return 1 }\nfn dead() i32 { return 2 }\n")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1003")
    defer w.deinit()
    assert_eq(w.len, 1 as usize, "pub and its callee are used; only the private orphan warns")
    assert_true(contains(w[0], "dead"), "and it is the orphan")
}

test "an exe's pub function is not a root" {
    let unit = exe_unit("pub fn helper() i32 { return 1 }\nfn main() i32 { return 0 }\n")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1003")
    defer w.deinit()
    assert_eq(w.len, 1 as usize, "pub does not excuse unreachable code in an executable")
}

test "a module with test blocks roots its non-pub functions" {
    let unit = exe_unit("fn probe() i32 { return 1 }\ntest \"t\" { let _x = 0 }\nfn main() i32 { return 0 }\n")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1003")
    defer w.deinit()
    assert_eq(w.len, 0 as usize, "the helper may exist only for the unchecked test body")
}

test "one overload used does not excuse its sibling" {
    let unit = exe_unit("fn f(x: i32) i32 { return x }\nfn f(x: bool) i32 { return 1 }\nfn main() i32 { return f(3i32) }\n")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1003")
    defer w.deinit()
    assert_eq(w.len, 1 as usize, "the bool overload is unused")
}

test "a function referenced as a value is used" {
    let unit = exe_unit("fn add(x: i32) i32 { return x + 1 }\nfn main() i32 {\n    let g: fn(i32) i32 = add\n    return g(1)\n}\n")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1003")
    defer w.deinit()
    assert_eq(w.len, 0 as usize, "a fn-value reference is a use")
}

test "a call inside a generic template body marks its target used" {
    let unit = exe_unit("fn helper() i32 { return 3 }\nfn pick(x: $T) i32 { return helper() }\nfn main() i32 { return pick(1i32) }\n")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1003")
    defer w.deinit()
    assert_eq(w.len, 0 as usize, "the overlay edge reaches the helper")
}

test "an operator overload used through its operator is not unused" {
    let unit = exe_unit("type P = struct { x: i32 }\nfn op_eq(a: &P, b: &P) bool { return a.x == b.x }\nfn main() i32 {\n    let a = P { x = 1 }\n    let b = P { x = 1 }\n    if a == b { return 0 }\n    return 1\n}\n")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1003")
    defer w.deinit()
    assert_eq(w.len, 0 as usize, "recorded operator dispatch is a use")
}

test "a use in a constant initializer roots the callee" {
    let unit = exe_unit("fn seed() i32 { return 7 }\nconst START: i32 = seed()\nfn main() i32 { return START }\n")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1003")
    defer w.deinit()
    assert_eq(w.len, 0 as usize, "a top-level site roots its target")
}

test "an import nothing uses warns W1004" {
    let unit = analyzed_fixture("import p.leaf

fn main() i32 {
    return 0
}
")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1004")
    defer w.deinit()
    assert_eq(w.len, 1 as usize, "the untouched import warns")
    assert_true(contains(w[0], "p.leaf"), "and names its module")
}

test "a called import does not warn W1004" {
    let unit = analyzed_fixture("import p.leaf

fn main() i32 {
    return leaf()
}
")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1004")
    defer w.deinit()
    assert_eq(w.len, 0 as usize, "a resolved call is a use")
}

test "a type-only use counts for W1004" {
    let unit = analyzed_fixture("import p.leaf

fn measure(m: &Marker) i32 {
    return 0
}

fn main() i32 {
    return 0
}
")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1004")
    defer w.deinit()
    assert_eq(w.len, 0 as usize, "a nominal cited by a signature keeps the import")
}

test "a pub import never warns W1004" {
    let unit = analyzed_fixture("pub import p.leaf

fn main() i32 {
    return 0
}
")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1004")
    defer w.deinit()
    assert_eq(w.len, 0 as usize, "re-export is the import's purpose")
}

test "a test-bearing module keeps its imports" {
    let unit = analyzed_fixture("import p.leaf

test \"maybe the test uses it\" {
    let _v = leaf()
}

fn main() i32 {
    return 0
}
")
    defer unit.deinit()
    let w = diag_messages(&unit, "W1004")
    defer w.deinit()
    assert_eq(w.len, 0 as usize, "unchecked test bodies may be the only use")
}
