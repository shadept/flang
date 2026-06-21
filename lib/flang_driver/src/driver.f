// flang_driver — the compile pipeline as a library: source text in, a
// checked `AnalyzedUnit` out (AST + type-check result + combined parse and
// check diagnostics). This is the single analysis entry point shared by
// every front-end exe — `flang build`, `flang test`, and the LSP — each of
// which is a thin `main` over `analyze`.
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
import std.list
import std.option
import std.set
import std.string
import std.string_builder
import flang_parser.lexer
import flang_parser.parser
import flang_parser.projector
import flang_parser.ast
import flang_core.diagnostic
import flang_core.span
import flang_typer.checker
import flang_typer.result
import flang_driver.resolver

// A fully analysed compilation unit. `checked` is false when the source
// failed to parse — `result` is then an empty placeholder.
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
    let alloc = allocator.or_global()
    let diagnostics: List(Diagnostic) = list(0, alloc)
    const src = source.as_view()

    let lx = lexer(src, alloc)
    let tokens = lx.tokenize()
    let p = parser(tokens, alloc)
    const cst = p.parse_module()
    const module = project_module(cst, 0i32, alloc)

    // The AST views `source`, not the token structs — tokens and the parser
    // are dead once the Module exists. Drain parse diagnostics first so they
    // survive `p.deinit()`.
    drain_diagnostics(&diagnostics, &p.diagnostics)
    p.deinit()
    tokens.deinit()

    // A file that didn't parse is not type-checked.
    let checked = count_errors(&diagnostics) == 0
    let result = empty_result(alloc)
    if checked {
        let modules: List(Module) = list(1, alloc)
        modules.push(module)
        let paths: List(String) = list(1, alloc)
        paths.push(path)

        let chk = checker(alloc)
        result = check_all(&chk, &modules, &paths)
        drain_diagnostics(&diagnostics, &chk.diagnostics)
        chk.deinit()

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
    // ponytail: the TypeCheckResult is leaked — flang_typer has no
    // result.deinit() yet. Fine for one-shot build/test; add result.deinit()
    // before the LSP re-analyses on every keystroke. See docs/known-issues.md.
}

// Error-severity diagnostics only — warnings and hints don't fail a build.
pub fn error_count(self: &AnalyzedUnit) usize {
    return count_errors(&self.diagnostics)
}

// Move every diagnostic from `src` into `dst`. `src.clear()` resets the
// length without deiniting elements, so the moved OwnedString messages are
// owned once (by `dst`) and never double-freed.
fn drain_diagnostics(dst: &List(Diagnostic), src: &List(Diagnostic)) {
    for i in 0..src.len {
        dst.push(src[i])
    }
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
    result: TypeCheckResult
    checked: bool
    diagnostics: List(Diagnostic)
}

pub fn analyze_project(ctx: &ResolveCtx, entries: &List(OwnedString), allocator: &Allocator? = null) AnalyzedProject {
    let alloc = allocator.or_global()
    let diagnostics: List(Diagnostic) = list(0, alloc)
    let sources: List(OwnedString) = list(0, alloc)
    let fqns: List(OwnedString) = list(0, alloc)
    let file_paths: List(OwnedString) = list(0, alloc)
    let modules: List(Module) = list(0, alloc)

    // BFS over the import graph, deduplicated by file path.
    let queue: List(OwnedString) = list(0, alloc)
    let seen: Set(String) = set(alloc)
    for i in 0..entries.len {
        enqueue_copy(&queue, &seen, entries[i].as_view())
    }
    seed_prelude(ctx, &queue, &seen, alloc)

    let qi: usize = 0
    while qi < queue.len {
        let path = queue[qi].as_view()
        qi = qi + 1
        let src_opt = read_text(path)
        if src_opt.is_none() {
            const msg = $"cannot read source `{path}`"
            diagnostics.push(error("E0001", msg, none_span()))
            continue
        }
        let src = src_opt.unwrap()
        let fid = modules.len as i32
        let module = parse_to_module(src.as_view(), fid, &diagnostics, alloc)
        let fqn = module_fqn(ctx, path, alloc)
        enqueue_imports(ctx, &module, &queue, &seen, &diagnostics, alloc)
        sources.push(src)
        file_paths.push(from_view(path))
        fqns.push(fqn)
        modules.push(module)
    }

    deinit_owned_list(&queue)
    seen.deinit()

    let checked = count_errors(&diagnostics) == 0
    let result = empty_result(alloc)
    if checked {
        let path_views: List(String) = list(modules.len, alloc)
        for i in 0..fqns.len {
            path_views.push(fqns[i].as_view())
        }
        let chk = checker(alloc)
        result = check_all(&chk, &modules, &path_views)
        drain_diagnostics(&diagnostics, &chk.diagnostics)
        chk.deinit()
        path_views.deinit()
    }

    return AnalyzedProject {
        sources = sources,
        fqns = fqns,
        file_paths = file_paths,
        modules = modules,
        result = result,
        checked = checked,
        diagnostics = diagnostics,
    }
}

pub fn deinit(self: &AnalyzedProject) {
    self.diagnostics.deinit()
    for i in 0..self.modules.len {
        self.modules[i].deinit()
    }
    self.modules.deinit()
    deinit_owned_list(&self.fqns)
    deinit_owned_list(&self.file_paths)
    deinit_owned_list(&self.sources)
    // ponytail: the TypeCheckResult is leaked — same as AnalyzedUnit, no
    // result.deinit() yet. Fine for one-shot build. See docs/known-issues.md.
}

// Total error-severity diagnostics across every module.
pub fn project_error_count(self: &AnalyzedProject) usize {
    return count_errors(&self.diagnostics)
}

fn parse_to_module(src: String, file_id: i32, diags: &List(Diagnostic), alloc: &Allocator) Module {
    let lx = lexer(src, alloc)
    let tokens = lx.tokenize()
    let p = parser(tokens, alloc)
    const cst = p.parse_module()
    const module = project_module(cst, file_id, alloc)
    drain_diagnostics(diags, &p.diagnostics)
    p.deinit()
    tokens.deinit()
    return module
}

fn enqueue_imports(ctx: &ResolveCtx, m: &Module, queue: &List(OwnedString), seen: &Set(String), diags: &List(Diagnostic), alloc: &Allocator) {
    for j in 0..m.decls.len {
        let d = &m.decls[j]
        d.* match {
            Import(id) => {
                let r = resolve_import(ctx, &id.path, alloc)
                r match {
                    Some(p) => enqueue_owned(queue, seen, p),
                    None => push_unresolved(diags, &id, alloc),
                }
            },
            _ => {},
        }
    }
}

fn seed_prelude(ctx: &ResolveCtx, queue: &List(OwnedString), seen: &Set(String), alloc: &Allocator) {
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

fn push_unresolved(diags: &List(Diagnostic), id: &ImportDecl, alloc: &Allocator) {
    let dotted = join_dotted(&id.path, alloc)
    const msg = $"unresolved import `{dotted.as_view()}`"
    dotted.deinit()
    diags.push(error("E0001", msg, id.span))
}

fn join_dotted(segs: &List(String), alloc: &Allocator) OwnedString {
    let sb = string_builder(0, alloc)
    for i in 0..segs.len {
        if i > 0 { sb.append('.') }
        sb.append(segs[i])
    }
    let out = sb.to_string()
    sb.deinit()
    return out
}

fn deinit_owned_list(l: &List(OwnedString)) {
    for i in 0..l.len {
        l[i].deinit()
    }
    l.deinit()
}
