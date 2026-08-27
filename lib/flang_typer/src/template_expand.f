// Source-generator expansion (RFC-021 §2): one worklist pass between
// nominal-name collection and body resolution. Each invocation's output
// is normalized (§7), parsed as a declaration chunk, collected, and
// appended to its ORIGIN module, so later invocations see the generated types and the generated
// declarations share the origin's FQN prefix and import scope. Nothing is written to disk; the
// driver may emit `<origin>.generated.f` from `emitted` when asked.
//
// Generated text is registered in the driver's file table (a padded copy per chunk, path
// `<origin>.generated.f`), so spans inside generated code render against the combined text the LSP
// and `--emit-generated` show.

import std.allocator
import std.dict
import std.env
import std.path
import std.list
import std.option
import std.result
import std.string
import std.string_builder
import flang_core.diagnostic
import flang_core.span
import flang_parser.ast
import flang_parser.comptime
import flang_parser.lexer
import flang_parser.parser
import flang_parser.projector
import flang_parser.template
import flang_typer.checker
import flang_typer.error_codes
import flang_typer.nominal_registry
import flang_typer.type
import flang_typer.visibility

pub const E_UNKNOWN_GENERATOR: String = "E2070"
pub const E_GENERATOR_ARITY: String = "E2071"
pub const E_GENERATOR_ARG_KIND: String = "E2072"
pub const E_TEMPLATE_DEPTH: String = "E2119"
const MAX_GENERATIONS: u32 = 8

// A `#define`, captured with its body text (a view into its source).
pub type GenDefEntry = struct {
    name: String
    params: List(GenParam)
    body: String
    base: usize
    file_id: i32
}

// Where a type declaration lives: `modules[module].decls[decl]`. Indices, not pointers - the decl
// list grows as chunks are appended.
pub type DeclRef = struct {
    module: usize
    decl: usize
}

// Generated text per origin file, for `--emit-generated` / the LSP.
pub type EmittedFile = struct {
    origin_path: String
    text: StringBuilder
    lines: usize
}

pub type TemplateState = struct {
    defs: Dict(OwnedString, GenDefEntry)
    syntax: Dict(OwnedString, DeclRef)
    chunk_modules: List(Module)
    emitted: List(EmittedFile)
    allocator: &Allocator?
}

pub fn template_state(allocator: &Allocator? = null) TemplateState {
    return .{
        defs = dict(allocator),
        syntax = dict(allocator),
        chunk_modules = list(0, allocator),
        emitted = list(0, allocator),
        allocator = allocator,
    }
}

// Generated modules and texts outlive the checker (lowering walks the appended decls): the driver
// takes them before `deinit`.
pub type TemplateOutput = struct {
    chunk_modules: List(Module)
    emitted: List(EmittedFile)
}

pub fn empty_template_output(allocator: &Allocator? = null) TemplateOutput {
    return .{ chunk_modules = list(0, allocator), emitted = list(0, allocator) }
}

pub fn take_output(self: &TemplateState) TemplateOutput {
    const out: TemplateOutput = .{ chunk_modules = self.chunk_modules, emitted = self.emitted }
    self.chunk_modules = list(0, self.allocator)
    self.emitted = list(0, self.allocator)
    return out
}

pub fn deinit(self: &EmittedFile) {
    self.text.deinit()
}

pub fn deinit(self: &TemplateOutput) {
    self.chunk_modules.deinit()
    self.emitted.deinit()
}

// Deliberately leak the output (single-unit analysis has no slot to keep it alive; the appended
// decls reference the chunk arenas). The modules are popped out before the list is freed.
pub fn forget(self: &TemplateState) {
    let out = self.take_output()
    while out.chunk_modules.pop().is_some() {}
    out.chunk_modules.deinit()
    self.defs.deinit()
    self.syntax.deinit()
}

pub fn deinit(self: &TemplateState) {
    self.defs.deinit()
    self.syntax.deinit()
    let rest = self.take_output()
    rest.deinit()
}

type WorkItem = struct {
    module: usize
    inv: GenInvoke
    generation: u32
}

type Outcome = enum {
    Expanded
    UnknownType
    Failed
}

// The lookup handed to the evaluator: resolves a type name in the invoking module's visibility to
// its declaration syntax.
type ExpandCtx = struct {
    chk: &Checker
    state: &TemplateState
    modules: &List(Module)
    vis: Visibility
    // Per-invocation arena: resolved declarations are boxed here so the pointers handed to the
    // evaluator outlive the match that found them (match payloads are copies).
    alloc: &Allocator
}

fn resolve_type_decl(raw: &u8, name: String) &TypeDecl? {
    const ctx = raw as &ExpandCtx
    const id: NominalId = ctx.chk.nominals.lookup(name, &ctx.vis) match {
        NomLookFound(i) => i
        _ => return null
    }
    const fqn = nominal_fqn(ctx.chk.nominals.get(id))
    const r: DeclRef = ctx.state.syntax.get(fqn) match {
        Some(r) => r
        None => return null
    }
    // Through a local: indexing a `&List` struct FIELD directly is miscompiled by the self-host
    // (docs/known-issues.md, 2026-08-23).
    const mods: &List(Module) = ctx.modules
    const decl: &Decl = &mods[r.module].decls[r.decl]
    decl.* match {
        Type(td) => return Some(box(ctx.alloc, td))
        _ => return null
    }
}

// ─────────────────────────────────────────────────────────────────────────
// The pass
// ─────────────────────────────────────────────────────────────────────────

// `sources[i]` / `file_paths[i]` back `modules[i]` (the driver's file table); generated chunks are
// appended to both so their file ids resolve. Runs after every module's nominal names are
// collected.
pub fn expand_templates(chk: &Checker, state: &TemplateState, modules: &List(Module),
    paths: &List(String), sources: &List(OwnedString), file_paths: &List(OwnedString)) {
    // Callers without a file table (typer unit tests) can't host template bodies; nothing to
    // expand.
    if sources.len < modules.len {
        return
    }
    let work: List(WorkItem) = list(0, chk.allocator)
    for m in 0..modules.len {
        index_module(state, &modules[m], m, 0, paths[m], sources[m].as_view(), &work, 0)
    }
    if work.len == 0 {
        return
    }

    loop {
        let parked: List(WorkItem) = list(0, chk.allocator)
        let progress = false
        for item in work {
            if item.generation >= MAX_GENERATIONS {
                push_diag_e(chk, item.inv.span, E_TEMPLATE_DEPTH,
                    $"Template expansion depth exceeded ({MAX_GENERATIONS}) at `#{item.inv.name}`")
                continue
            }
            const outcome = expand_one(chk, state, modules, paths, sources, file_paths, item,
                &parked)
            outcome match {
                Outcome.Expanded => { progress = true }
                Outcome.UnknownType => { parked.push(item) }
                Outcome.Failed => {}
            }
        }
        if !progress {
            for &item in parked { report_unknown_types(chk, state, paths, item) }
            break
        }
        work = parked
        if work.len == 0 {
            break
        }
    }
}

// Register a module's (or chunk's) generator definitions, type syntax and invocations. `first_decl`
// is where this module's new decls start in `modules[m].decls` (0 for an original module, the
// pre-append length for a chunk); `decl_base` offsets the DeclRef indices the same way.
fn index_module(state: &TemplateState, module: &Module, m: usize, decl_base: usize, path: String,
    source: String, work: &List(WorkItem), generation: u32) {
    let j: usize = 0
    for &d in module.decls {
        d.* match {
            GenDef(g) => {
                state.defs[$"{g.name}"] = GenDefEntry {
                    name = g.name,
                    params = g.params,
                    body = source[g.body_start..g.body_end],
                    base = g.body_start,
                    file_id = module.span.file_id,
                }
            }
            GenInvoke(inv) => { work.push(WorkItem { module = m, inv = inv,
                    generation = generation }) }
            Type(td) => {
                state.syntax[$"{path}.{td.name}"] = DeclRef { module = m, decl = decl_base + j }
            }
            _ => {}
        }
        j = j + 1
    }
}

fn expand_one(chk: &Checker, state: &TemplateState, modules: &List(Module), paths: &List(String),
    sources: &List(OwnedString), file_paths: &List(OwnedString), item: WorkItem,
    parked: &List(WorkItem)) Outcome {
    const inv = item.inv
    const found_def = state.defs.get(inv.name)
    if found_def.is_none() {
        push_diag_e(chk, inv.span, E_UNKNOWN_GENERATOR, $"Unknown source generator `{inv.name}`")
        return Outcome.Failed
    }
    const def: GenDefEntry = found_def.unwrap()

    const has_variadic = def.params.len > 0 and def.params[def.params.len - 1].variadic
    const required: usize = if has_variadic { def.params.len - 1 } else { def.params.len }
    const arity_ok = if has_variadic { inv.args.len >= required } else { inv.args.len == def.params.len }
    if !arity_ok {
        const expect: OwnedString = if has_variadic { $"at least {required}" } else { $"{def.params.len}" }
        push_diag_e(chk, inv.span, E_GENERATOR_ARITY,
            $"Source generator `{inv.name}` expects {expect} arguments, got {inv.args.len}")
        return Outcome.Failed
    }

    // Everything produced while expanding this one invocation lives here.
    let arena = arena_allocator(chk.allocator.or_global())
    defer arena.deinit()
    let a = arena.allocator()

    chk.set_current_module(paths[item.module])
    let ectx: ExpandCtx = .{ chk = chk, state = state, modules = modules,
        vis = current_visibility(chk), alloc = &a }
    defer ectx.vis.visible.deinit()
    const lookup: CtLookup = .{ ctx = &ectx as &u8, resolve = resolve_type_decl }
    let env = ct_env(&chk.comptime, &a, lookup)

    // Bind parameters. A `Type` argument whose nominal is not collected yet parks the invocation
    // (another expansion may produce it).
    for p in 0..def.params.len {
        const param = def.params[p]
        if param.variadic {
            let rest: List(CtValue) = list(inv.args.len - p, Some(&a))
            for i in p..inv.args.len {
                bind_arg(chk, &env, &param, &inv.args[i], inv.name, &a) match {
                    Ok(v) => rest.push(v)
                    Err(o) => return o
                }
            }
            env.bindings[param.name] = CtValue.List(rest)
            break
        }
        bind_arg(chk, &env, &param, &inv.args[p], inv.name, &a) match {
            Ok(v) => { env.bindings[param.name] = v }
            Err(o) => return o
        }
    }

    // Parse the body and expand.
    let parse_diags: List(Diagnostic) = list(0, Some(&a))
    const nodes = parse_template_body(def.body, def.base, def.file_id, &a, &parse_diags)
    if parse_diags.len > 0 {
        for &d in parse_diags { chk.diagnostics.push(error(d.code, d.message, d.span)) }
        parse_diags.clear()
        return Outcome.Failed
    }
    let raw = string_builder(def.body.len, Some(&a))
    expand_template(&env, &nodes, &raw) match {
        Ok(_) => {}
        Err(e) => {
            const sp: SourceSpan = .{ file_id = def.file_id, start = def.base + e.span.start,
                length = e.span.length }
            push_diag_e(chk, sp, e.code, $"{e.message} (while expanding `#{inv.name}`)")
            return Outcome.Failed
        }
    }

    // Readable output (§7), then the chunk header.
    let chunk = string_builder(raw.len + 64, Some(&a))
    chunk.append("// #")
    chunk.append(inv.name)
    chunk.append('(')
    let first = true
    for &arg in inv.args {
        if !first {
            chunk.append(", ")
        }
        first = false
        arg.* match {
            IdentArg(id) => chunk.append(id.name)
            TypeArg(te) => spell_type_into(&chunk, &te)
        }
    }
    chunk.append(")\n")
    normalize_generated(raw.as_view(), &chunk)
    chunk.append('\n')

    // Register the chunk as a padded file entry so its spans line up with the combined generated
    // text for this origin.
    const emitted = emitted_for(state, chk.allocator, file_paths[item.module].as_view())
    const lines_before = emitted.lines
    let padded = string_builder(chunk.len + lines_before, chk.allocator)
    for _i in 0..lines_before { padded.append('\n') }
    padded.append(chunk.as_view())
    emitted.text.append(chunk.as_view())
    emitted.lines = lines_before + count_lines(chunk.as_view())

    if env("FLANG_DEBUG_TEMPLATES").is_some() {
        println(chunk.as_view())
    }
    const file_id = sources.len as i32
    sources.push(padded.to_string())
    file_paths.push($"{generated_path(file_paths[item.module].as_view())}")

    // Parse the chunk, collect its nominals, fold it into the origin.
    let chunk_module = parse_chunk(chk, sources[sources.len - 1].as_view(), file_id)
    collect_nominal_names(chk, &chunk_module, paths[item.module])
    let origin = &modules[item.module]
    const decl_base = origin.decls.len
    origin.append_decls(&chunk_module.decls)
    index_module(state, &chunk_module, item.module, decl_base, paths[item.module],
        sources[sources.len - 1].as_view(), parked, item.generation + 1)
    state.chunk_modules.push(chunk_module)
    return Outcome.Expanded
}

fn bind_arg(chk: &Checker, env: &CtEnv, param: &GenParam, arg: &GenArg, gen_name: String,
    a: &Allocator) Result(CtValue, Outcome) {
    if param.kind == "Ident" {
        return arg.* match {
            IdentArg(id) => Ok(CtValue.Ident(id.name))
            _ => {
                push_diag_e(chk, gen_arg_span(arg), E_GENERATOR_ARG_KIND,
                    $"Source generator `{gen_name}` parameter `{param.name}` expects an identifier")
                Err(Outcome.Failed)
            }
        }
    }
    if param.kind == "Type" {
        return arg.* match {
            // Boxed: the match payload is a copy, and CtTypeInfo retains the pointer past this call
            // (FromSyntax).
            TypeArg(te) => Ok(CtValue.TypeInfo(type_info_of(env, box(a, te))))
            IdentArg(id) => {
                if !type_is_collected(chk, id.name) {
                    return Err(Outcome.UnknownType)
                }
                const named: TypeExpr = TypeExpr.Named(NamedType { span = id.span, name = id.name,
                    generic_args = list(0, Some(a)) })
                Ok(CtValue.TypeInfo(type_info_of(env, box(a, named))))
            }
        }
    }
    push_diag_e(chk, param.span, E_GENERATOR_ARG_KIND,
        $"Unknown generator parameter kind `{param.kind}` (expected `Ident` or `Type`)")
    return Err(Outcome.Failed)
}

fn gen_arg_span(arg: &GenArg) SourceSpan {
    return arg.* match {
        IdentArg(id) => id.span
        TypeArg(te) => type_expr_span(&te)
    }
}

fn type_is_collected(chk: &Checker, name: String) bool {
    if is_primitive_name(name) {
        return true
    }
    const vis = current_visibility(chk)
    defer vis.visible.deinit()
    return chk.nominals.lookup(name, &vis) match {
        NomLookFound(_) => true
        _ => false
    }
}

fn report_unknown_types(chk: &Checker, state: &TemplateState, paths: &List(String),
    item: &WorkItem) {
    const found = state.defs.get(item.inv.name)
    if found.is_none() {
        return
    }
    const def: GenDefEntry = found.unwrap()
    chk.set_current_module(paths[item.module])
    for p in 0..def.params.len {
        if p >= item.inv.args.len {
            break
        }
        const param = def.params[p]
        if param.variadic {
            break
        }
        if param.kind != "Type" {
            continue
        }
        item.inv.args[p] match {
            IdentArg(id) => {
                if !type_is_collected(chk, id.name) {
                    push_diag_e(chk, id.span, E_UNKNOWN_TYPE, $"Unknown type `{id.name}`")
                }
            }
            _ => {}
        }
    }
}

fn parse_chunk(chk: &Checker, text: String, file_id: i32) Module {
    let lx = lexer(text, chk.allocator)
    let tokens = lx.tokenize()
    let p = parser(tokens, chk.allocator)
    p.set_file_id(file_id)
    const cst = p.parse_module()
    let module = project_module(cst, file_id, chk.allocator)
    flatten_module_decls(&module, &chk.comptime, &chk.diagnostics, chk.allocator)
    for &d in p.diagnostics { chk.diagnostics.push(error(d.code, d.message, d.span)) }
    p.diagnostics.clear()
    p.deinit()
    tokens.deinit()
    return module
}

fn emitted_for(state: &TemplateState, allocator: &Allocator?, origin_path: String) &EmittedFile {
    for i in 0..state.emitted.len {
        if state.emitted[i].origin_path == origin_path {
            return &state.emitted[i]
        }
    }
    let text = string_builder(256, allocator)
    text.append("// Generated from ")
    text.append(base_name(origin_path))
    text.append("\n\n")
    state.emitted.push(EmittedFile { origin_path = origin_path, text = text, lines = 2 })
    return &state.emitted[state.emitted.len - 1]
}

fn base_name(p: String) String {
    return path(p).file_name() ?? p
}

// `foo.f` → `foo.generated.f`
pub fn generated_path(origin: String) OwnedString {
    if origin.ends_with(".f") {
        return $"{origin[0..origin.len - 2]}.generated.f"

    }
    return $"{origin}.generated.f"
}

fn count_lines(text: String) usize {
    let n: usize = 0
    for c in text.as_raw_bytes() { if c == '\n' as u8 {
            n = n + 1
        } }
    return n
}

// ─────────────────────────────────────────────────────────────────────────
// Readable output (§7)
// ─────────────────────────────────────────────────────────────────────────

// Re-indents generated text by brace depth (2 spaces per level), drops trailing whitespace and
// collapses blank-line runs to one. Template-body indentation is not significant. Braces are
// counted outside string / char literals and line comments. ponytail: text-level normalizer; a CST
// formatter replaces this wholesale when one exists.
pub fn normalize_generated(text: String, out: &StringBuilder) {
    let depth: usize = 0
    let blank_run = true // suppress leading blank lines
    let line_start: usize = 0
    let pos: usize = 0
    const n = text.len
    loop {
        if pos > n {
            break
        }
        if pos == n or text[pos] == '\n' as u8 {
            const line = trim(text[line_start..pos])
            if line.len == 0 {
                if !blank_run {
                    out.append('\n')
                }
                blank_run = true
            } else {
                const braces = count_braces(line)
                const opens = braces.0
                const closes = braces.1
                // A line that starts by closing dedents before printing.
                let indent = depth
                if line[0] == '}' as u8 and indent > 0 {
                    indent = indent - 1
                }
                for _i in 0..indent { out.append("  ") }
                out.append(line)
                out.append('\n')
                depth = depth + opens
                depth = if closes > depth { 0 } else { depth - closes }
                blank_run = false
            }
            line_start = pos + 1
        }
        pos = pos + 1
    }
}

// (opens, closes) outside strings, chars and line comments.
fn count_braces(line: String) (usize, usize) {
    let opens: usize = 0
    let closes: usize = 0
    let in_string = false
    let in_char = false
    let prev: u8 = 0
    for c in line.as_raw_bytes() {
        if !in_string and !in_char and c == '/' as u8 and prev == '/' as u8 {
            break
        }
        if in_string {
            if c == '"' as u8 and prev != '\\' as u8 {
                in_string = false
            }
        } else if in_char {
            if c == '\'' as u8 and prev != '\\' as u8 {
                in_char = false
            }
        } else if c == '"' as u8 {
            in_string = true
        } else if c == '\'' as u8 {
            in_char = true
        } else if c == '{' as u8 {
            opens = opens + 1
        } else if c == '}' as u8 {
            closes = closes + 1
        }
        prev = c
    }
    return (opens, closes)
}
