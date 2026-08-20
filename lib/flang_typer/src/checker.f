// Checker driver - wires the engine, registries, env, and results
// into the three public phases:
//
//   - `collect_nominal_names` then `resolve_nominal_bodies` build the
//     `NominalRegistry`. Every type-decl across every module is registered
//     before any field or variant payload is resolved, so references
//     between types resolve regardless of declaration or module order.
//
//   - `collect_signatures(modules, &nominals, &diags)` builds the
//     `FunctionRegistry`. Type-decl bodies are already resolved by
//     this point so signature TypeNode → `Ty` resolution can rely on
//     the registry being complete.
//
//   - `check_module_bodies(module, &nominals, &functions, &diags)`
//     walks every function body and produces `InferenceResults`.
//
// Plus the convenience entry point:
//
//   - `check_all(modules, &diags) TypeCheckResult` - runs the three
//     phases and zonks the engine into an immutable result. The
//     engine is dropped before this returns.
//
// Expression, statement, and declaration handling all live in this
// file today; split into per-category modules when match/pattern
// checking lands and the dispatchers stop fitting in one screen.
// Module-level state (engine, env, ctx) is bundled into a `Checker`
// struct passed by reference to every sub-routine - no global state.

import std.allocator
import std.dict
import std.list
import std.option
import std.set
import std.string
import std.string_builder
import std.test
import flang_core.diagnostic
import flang_core.span
import flang_parser.ast
import flang_parser.lexer
import flang_parser.parser
import flang_parser.projector
import flang_typer.type
import flang_typer.well_known
import flang_typer.scheme
import flang_typer.env
import flang_typer.inference_engine
import flang_typer.inference_results
import flang_typer.nominal_registry
import flang_typer.fqn_map
import flang_typer.function_registry
import flang_typer.specialization
import flang_typer.substitution
import flang_typer.visibility
import flang_typer.node_id
import flang_typer.error_codes
import flang_typer.reporter
import flang_typer.result

// One function's lexical context: the declared return type so
// `ReturnStmt` can unify against it, and the function's name for
// diagnostics. Pushed onto the checker's `fn_stack` on entry, popped
// on exit.
pub type FnFrame = struct {
    name: String
    return_ty: Ty
    decl_span: SourceSpan
}

// What instantiating a generic template needs (M10): the declaration to
// re-check, its defining module, and the signature's type params in
// declaration order. `decl` is a shallow copy - children stay in the
// module's arena, which outlives the check.
type GenericTemplate = struct {
    decl: FunctionDecl
    module: String
    tps: List(SigTypeParam)       // signature type params, declaration order
}

// One `$T` binding created while resolving the current signature -
// collected by `resolve_generic_bind`, drained by `register_function_sig`.
type SigTypeParam = struct {
    name: String
    var_id: VarId
}

// An unsuffixed numeric literal's fresh var, held for the post-inference
// sweep: still unresolved once everything has settled means no context
// ever pinned the literal - E2001, matching the reference.
type PendingLit = struct {
    span: SourceSpan
    ty: Ty
    text: String
    is_float: bool
}

// An anonymous `.{ ... }` literal awaiting its nominal. The literal
// types as a fresh var the surrounding context binds; once inference
// settles, each field initializer unifies against the nominal's
// declared (substituted) field type - which is what pins unsuffixed
// numeric fields and rejects mismatched initializers.
type PendingAnon = struct {
    ty: Ty
    fields: List(AnonFieldRec)
}

type AnonFieldRec = struct {
    name: String
    ty: Ty
    span: SourceSpan
}

// A committed pick of a generic overload, awaiting instantiation. The
// fresh vars inside `tp_binds` / `inst_params` / `inst_ret` zonk to
// concrete types once the enclosing body's inference settles; the
// post-pass then instantiates the template and rewrites the node's
// table entry (`resolved_targets` for calls, `resolved_ops` for
// operators) to cite the specialization.
type PendingSpec = struct {
    span: SourceSpan
    is_operator: bool
    function_id: u32
    tp_binds: Dict(VarId, Ty)     // template quantified id → call-site fresh var
    inst_params: List(Ty)
    inst_ret: Ty
    // The module whose body recorded the pick - unioned into visibility
    // while the instantiation checks, so the template body resolves
    // overloads the call site can see (the `hash()`-for-`Dict` contract).
    caller_module: String
}

pub type Checker = struct {
    engine: Engine
    env: TypeEnv
    nominals: NominalRegistry
    // Type-alias bodies (expanded lazily at use) and module-level constant
    // types, both FQN-keyed with import-visibility lookup.
    aliases: FqnMap(TypeExpr)
    constants: FqnMap(Ty)
    functions: FunctionRegistry
    specs: SpecializationRegistry
    results: InferenceResults
    diagnostics: List(Diagnostic)

    // Working state - reset between modules.
    current_module: String?
    fn_stack: List(FnFrame)

    // M10 - specialization state.
    // fn_id → what instantiation needs (generic functions only).
    templates: Dict(u32, GenericTemplate)
    // `$T` bindings of the signature currently being registered, in
    // declaration order.
    sig_tps: List(SigTypeParam)
    // Generic picks recorded while checking the current body scope;
    // drained after phase 3 (and, nested, after each instantiation's
    // body check - `instantiate` swaps in a fresh list).
    pending_specs: List(PendingSpec)
    // Caller-module chain of the instantiations in progress - unioned
    // into `current_visibility` so a template body resolves overloads
    // its call sites can see.
    spec_callers: List(String)
    // Guard against runaway instantiation chains (infinitely recursive
    // polymorphism).
    spec_depth: usize
    // Unsuffixed numeric literals awaiting the post-inference sweep.
    pending_literals: List(PendingLit)
    // Anonymous literals awaiting their nominal - resolved per body
    // scope, before that scope's specialization drain (a pinned field
    // can be what makes a generic pick's signature concrete).
    pending_anons: List(PendingAnon)

    // Module FQN -> the set of module FQNs whose `pub` declarations are
    // visible from it. Built once per `check_all` from the modules'
    // imports: direct imports plus the transitive `pub import` closure,
    // plus the auto-imported core prelude.
    visible_by_module: Dict(OwnedString, Set(String))

    // Monotonic counter behind `synth_span`: gives every checker-
    // synthesized AST node (interpolation desugar) a node id no real
    // node can collide with. Also names the desugar's builder locals.
    next_synth: u32

    allocator: &Allocator?
}

pub fn checker(allocator: &Allocator? = null) Checker {
    return .{
        engine = engine(allocator),
        env = type_env(allocator),
        nominals = nominal_registry(allocator),
        aliases = fqn_map(allocator),
        constants = fqn_map(allocator),
        functions = function_registry(allocator),
        specs = specialization_registry(allocator),
        results = inference_results(allocator),
        diagnostics = list(0, allocator),
        current_module = null,
        fn_stack = list(0, allocator),
        templates = dict(allocator),
        sig_tps = list(0, allocator),
        pending_specs = list(0, allocator),
        spec_callers = list(0, allocator),
        spec_depth = 0usize,
        pending_literals = list(0, allocator),
        pending_anons = list(0, allocator),
        visible_by_module = dict(allocator),
        next_synth = 0u32,
        allocator = allocator,
    }
}

pub fn deinit(self: &Checker) {
    self.engine.deinit()
    self.env.deinit()
    self.nominals.deinit()
    self.aliases.deinit()
    self.constants.deinit()
    self.functions.deinit()
    self.specs.deinit()
    self.results.deinit()
    self.diagnostics.deinit()
    self.fn_stack.deinit()
    self.templates.deinit()
    self.sig_tps.deinit()
    self.pending_specs.deinit()
    self.spec_callers.deinit()
    self.pending_literals.deinit()
    self.pending_anons.deinit()
    self.visible_by_module.deinit()
}

// ─────────────────────────────────────────────────────────────────────
// Resolving TypeExpr → Ty
//
// The parser's AST has a `TypeExpr` enum that mirrors source-level
// type syntax: `Named`, `Generic`, `Reference`, `Optional`, `Array`,
// `Slice`, `Tuple`, `Function`, anonymous struct, anonymous enum,
// `GenericBind` (the `$T` introducer), and `Error`. The resolver
// walks this and produces a `Ty`.
//
// Type aliases resolve transparently here: `resolve_named` consults the
// alias registry after the primitive and nominal lookups and expands the
// stored body lazily, so alias chains and cross-module targets resolve
// regardless of declaration order.
// ─────────────────────────────────────────────────────────────────────

pub fn resolve_type_expr(self: &Checker, te: &TypeExpr) Ty {
    return te.* match {
        Named(n) => resolve_named(self, &n),
        Reference(r) => resolve_reference(self, &r),
        Optional(o) => resolve_optional(self, &o),
        Array(a) => resolve_array(self, &a),
        Slice(s) => resolve_slice(self, &s),
        Tuple(t) => resolve_tuple(self, &t),
        Function(f) => resolve_function(self, &f),
        GenericBind(g) => resolve_generic_bind(self, &g),
        _ => Ty.Error,
    }
}

fn resolve_named(self: &Checker, n: &NamedType) Ty {
    // Primitive?
    let prim = prim_from_name(n.name)
    if prim.is_some() { return Ty.Prim(prim.unwrap()) }

    // Builtin non-primitive types.
    if n.name == "void" { return Ty.Void }
    if n.name == "never" { return Ty.Never }

    // A type parameter in scope shadows every nominal - it is the
    // innermost binding. Without this, a project type named `E`
    // captures the stdlib's `enum(T, E)` payload declarations through
    // the program-wide nominal fallback below, poisoning the registry
    // for the whole compilation.
    let tp = self.env.lookup(n.name)
    if tp.is_some() {
        let b = tp.unwrap()
        if b.is_type_param { return self.engine.specialize(&b.scheme) }
    }

    // Nominal?
    let vis = current_visibility(self)
    let look = self.nominals.lookup(n.name, &vis)

    let found_id: NominalId? = look match {
        NomLookFound(id) => Some(id),
        _ => null,
    }
    if found_id.is_some() {
        let args = resolve_generic_args(self, n)
        return Ty.Nominal(NominalRef { id = found_id.unwrap(), args = args })
    }

    // Alias? Expand its stored body lazily. Resolving the body here (rather
    // than at registration) handles alias chains and cross-module targets
    // without ordering concerns.
    // ponytail: non-generic aliases only; no cycle guard (the self-host
    // sources have none). Generic aliases and cycle detection are follow-ups.
    let alias_body = self.aliases.lookup(n.name, &vis)
    if alias_body.is_some() {
        let body = alias_body.unwrap()
        return resolve_type_expr(self, &body)
    }

    // A registered type outside the import scope still resolves: the
    // reference compiler resolves type names program-wide regardless of
    // imports, and the stdlib depends on it. Import-strict type visibility
    // is a future tightening (identifiers stay strict).
    let hidden_info: NomHiddenInfo? = look match {
        NomLookHidden(info) => Some(info),
        _ => null,
    }
    if hidden_info.is_some() {
        let info = hidden_info.unwrap()
        let args = resolve_generic_args(self, n)
        return Ty.Nominal(NominalRef { id = info.id, args = args })
    }

    push_diag_e(self, n.span, E_UNKNOWN_TYPE, $"unknown type `{n.name}`")
    return Ty.Error
}

fn resolve_generic_args(self: &Checker, n: &NamedType) List(Ty) {
    let out: List(Ty) = list(n.generic_args.len, self.allocator)
    for i in 0..n.generic_args.len {
        let arg = &n.generic_args[i]
        out.push(resolve_type_expr(self, arg))
    }
    return out
}

fn resolve_reference(self: &Checker, r: &ReferenceType) Ty {
    let inner = resolve_type_expr(self, r.inner)
    return self.engine.mk_ref(inner)
}

fn resolve_optional(self: &Checker, o: &OptionalType) Ty {
    let inner = resolve_type_expr(self, o.inner)
    let opt_id = self.nominals.by_fqn.get(FQN_OPTION)
    if opt_id.is_none() { return Ty.Error }
    let args: List(Ty) = list(1, self.allocator)
    args.push(inner)
    return Ty.Nominal(NominalRef { id = opt_id.unwrap(), args = args })
}

fn resolve_array(self: &Checker, a: &ArrayType) Ty {
    let elem = resolve_type_expr(self, a.element)
    // Array length is an expr in the parser AST; for first slice we
    // only handle integer-literal lengths. Anything else surfaces as
    // a `0`-sized array - the parser would already have surfaced the
    // expression-evaluation error.
    let length = array_length_of(a.length)
    return self.engine.mk_array(elem, length)
}

// A declared array length. Only plain integer-literal lengths evaluate
// (the only form the corpus writes); anything else stays 0 until a
// const_eval pass exists. M10 made this load-bearing: array literals
// now type as `[T; len]`, so a declared `u8[1024]` must size to 1024 or
// every literal-vs-declared unify fails on length.
fn array_length_of(e: &Expr) usize {
    return literal_count_of(e) match {
        Some(n) => n,
        None => 0usize,
    }
}

fn resolve_slice(self: &Checker, s: &SliceType) Ty {
    let elem = resolve_type_expr(self, s.element)
    let slice_id = self.nominals.by_fqn.get(FQN_SLICE)
    if slice_id.is_none() { return Ty.Error }
    let args: List(Ty) = list(1, self.allocator)
    args.push(elem)
    return Ty.Nominal(NominalRef { id = slice_id.unwrap(), args = args })
}

fn resolve_tuple(self: &Checker, t: &TupleType) Ty {
    let elems: List(Ty) = list(t.elements.len, self.allocator)
    for i in 0..t.elements.len {
        let e = &t.elements[i]
        elems.push(resolve_type_expr(self, e))
    }
    return Ty.Tuple(elems)
}

fn resolve_function(self: &Checker, f: &FunctionType) Ty {
    let params: List(Ty) = list(f.params.len, self.allocator)
    for i in 0..f.params.len {
        let p = &f.params[i]
        params.push(resolve_type_expr(self, p))
    }
    let ret = f.return_type match {
        Some(rt) => resolve_type_expr(self, rt),
        None => Ty.Void,
    }
    return self.engine.mk_func(params, ret)
}

fn resolve_generic_bind(self: &Checker, g: &GenericBindType) Ty {
    // `$T` introduces a type parameter. Each binding becomes a fresh
    // variable scoped to the function's signature; subsequent `T`
    // references look it up from the env. During an instantiation's
    // re-check the name is pre-bound to a concrete type, so the lookup
    // path returns that instead of minting a var.
    let existing = self.env.lookup(g.name)
    if existing.is_some() { return self.engine.specialize(&existing.unwrap().scheme) }
    let fresh = self.engine.fresh_var()
    let vid = fresh match { Var(v) => v.id, _ => 0u32 }
    self.sig_tps.push(SigTypeParam { name = g.name, var_id = vid })
    self.env.bind(g.name, Binding {
        scheme = mono(fresh, self.allocator),
        decl = node_id_of(g.span),
        is_const = true,
        is_type_param = true,
    })
    return fresh
}

// ─────────────────────────────────────────────────────────────────────
// Diagnostic helpers - small, lift to reporter when complexity grows.
// ─────────────────────────────────────────────────────────────────────

pub fn push_diag_e(self: &Checker, span: SourceSpan, code: String, message: OwnedString) {
    let empty_hint: OwnedString
    self.diagnostics.push(Diagnostic {
        severity = Severity.Error,
        code = code,
        message = message,
        hint = empty_hint,
        span = span,
    })
}

// Translate a unify outcome into a diagnostic anchored at `span`. A
// `Unified` outcome produces nothing; every mismatch produces one
// diagnostic on the checker's list.
fn report_unify(self: &Checker, outcome: &UnifyOutcome, code: String, span: SourceSpan) {
    let ctx = report_ctx(code, span)
    report(outcome, &ctx, &self.diagnostics, self.allocator)
}

pub fn current_visibility(self: &Checker) Visibility {
    return self.current_module match {
        Some(m) => visibility(Some(m), base_visible_set(self, m)),
        None => open(self.allocator),
    }
}

// The modules visible from `m`, as a fresh caller-owned set.
fn base_visible_set(self: &Checker, m: String) Set(String) {
    let fresh: Set(String) = set(self.allocator)
    self.visible_by_module.get(m) match {
        Some(src) => copy_set_into(&fresh, &src),
        None => fresh.add(m),
    }
    return fresh
}

// Visibility for FUNCTION lookups. A template body under instantiation
// also dispatches to overloads its caller chain imports (`hash()` for
// `Dict`) - deliberately caller-dependent: the FIRST instantiation of a
// signature fixes the winning targets for everyone. The union applies
// to functions ONLY: widening nominal/variant lookups the same way lets
// a caller's `Decl.Type(...)` variant capture the template's
// `Type(T)` RTTI expression (found the hard way in `std.allocator.box`
// instantiated from the projector).
fn fn_visibility(self: &Checker) Visibility {
    if self.spec_callers.len == 0 { return current_visibility(self) }
    return self.current_module match {
        Some(m) => {
            // Built locally before wrapping - growing a set through a
            // returned struct's field is the two-field-hop hazard.
            let fresh = base_visible_set(self, m)
            for i in 0..self.spec_callers.len {
                let c = self.spec_callers[i]
                fresh.add(c)
                self.visible_by_module.get(c) match {
                    Some(src) => copy_set_into(&fresh, &src),
                    None => {},
                }
            }
            visibility(Some(m), fresh)
        },
        None => open(self.allocator),
    }
}

// ponytail: rebuilds the returned set per lookup; cache on the checker if
// profiling flags it. The reads stay O(visible-module-count), which is small.
fn copy_set_into(dst: &Set(String), src: &Set(String)) {
    let it = src.iter()
    loop {
        let n = it.next()
        if n.is_none() { break }
        dst.add(n.unwrap())
    }
}

// Build `visible_by_module` from the modules' import declarations: each
// module sees itself, its direct imports, the `pub import` transitive
// closure reachable through them, and the auto-imported core prelude.
fn build_visibility(self: &Checker, modules: &List(Module), paths: &List(String)) {
    let alloc = self.allocator
    let n = modules.len

    // Per-module edge lists (views into `paths`): all imports, and the
    // `pub import` subset that re-exports transitively.
    let imports: List(List(String)) = list(0, alloc)
    let reexports: List(List(String)) = list(0, alloc)
    for i in 0..n {
        let imps: List(String) = list(0, alloc)
        let reexps: List(String) = list(0, alloc)
        collect_edges(&modules[i], paths, &imps, &reexps, alloc)
        if paths[i] != "core.prelude" {
            let pre = find_fqn(paths, "core.prelude")
            if pre.is_some() {
                let pv = pre.unwrap()
                if !contains_view(&imps, pv) { imps.push(pv) }
            }
        }
        imports.push(imps)
        reexports.push(reexps)
    }

    for i in 0..n {
        let vis: Set(String) = set(alloc)
        compute_visible(i, paths, &imports, &reexports, &vis, alloc)
        self.visible_by_module.set(paths[i], vis)
    }

    imports.deinit()
    reexports.deinit()
}

// Record module `m`'s imports as views into `paths`. An import whose
// dotted path names no loaded module is silently dropped here; the
// unresolved-import diagnostic is the loader's job.
fn collect_edges(m: &Module, paths: &List(String), imps: &List(String), reexps: &List(String), alloc: &Allocator?) {
    for j in 0..m.decls.len {
        let d = &m.decls[j]
        d.* match {
            Import(id) => {
                let dotted = dot_join(&id.path, alloc)
                let fv = find_fqn(paths, dotted.as_view())
                dotted.deinit()
                if fv.is_some() {
                    let v = fv.unwrap()
                    if !contains_view(imps, v) { imps.push(v) }
                    if id.is_pub {
                        if !contains_view(reexps, v) { reexps.push(v) }
                    }
                }
            },
            _ => {},
        }
    }
}

// `{idx} ∪ imports(idx)` then a BFS that follows only `pub import` edges,
// per the spec's non-transitive-import / transitive-re-export rule.
fn compute_visible(idx: usize, paths: &List(String), imports: &List(List(String)), reexports: &List(List(String)), out: &Set(String), alloc: &Allocator?) {
    out.add(paths[idx])
    let work: List(String) = list(0, alloc)
    let imps = &imports[idx]
    for k in 0..imps.len {
        let im = imps[k]
        if !out.contains(im) {
            out.add(im)
            work.push(im)
        }
    }
    let head: usize = 0
    while head < work.len {
        let node = work[head]
        head = head + 1
        let ni = find_index(paths, node)
        if ni.is_some() {
            let re = &reexports[ni.unwrap()]
            for k in 0..re.len {
                let rv = re[k]
                if !out.contains(rv) {
                    out.add(rv)
                    work.push(rv)
                }
            }
        }
    }
    work.deinit()
}

pub fn dot_join(segs: &List(String), alloc: &Allocator?) OwnedString {
    let sb = string_builder(0, alloc)
    defer sb.deinit()
    for i in 0..segs.len {
        if i > 0 { sb.append('.') }
        sb.append(segs[i])
    }
    return sb.to_string()
}

// ponytail: linear scans over `paths`; index by FQN if module counts grow.
fn find_fqn(paths: &List(String), name: String) String? {
    for i in 0..paths.len {
        if paths[i] == name { return Some(paths[i]) }
    }
    return null
}

fn find_index(paths: &List(String), name: String) usize? {
    for i in 0..paths.len {
        if paths[i] == name { return Some(i) }
    }
    return null
}

fn contains_view(list: &List(String), v: String) bool {
    for i in 0..list.len {
        if list[i] == v { return true }
    }
    return false
}

// ─────────────────────────────────────────────────────────────────────
// Phase 1 - collect nominal types
//
// First pass: register every struct/enum/alias by FQN with a
// placeholder definition (empty fields/variants). Second pass: resolve
// each declaration's fields/variants now that every name in the module
// is known.
// ─────────────────────────────────────────────────────────────────────

// Register one module's type *names* (struct/enum placeholders). Bodies are
// resolved in a separate pass - see `resolve_nominal_bodies` - so a field or
// variant payload can reference a type declared in any module, in any order.
pub fn collect_nominal_names(self: &Checker, module: &Module, module_path: String) {
    self.current_module = Some(module_path)
    for i in 0..module.decls.len {
        let decl = &module.decls[i]
        collect_one_name(self, decl, module_path)
    }
}

// Resolve one module's type bodies (struct fields, enum payloads). Runs only
// after every module's names are registered, so cross-module references in a
// body resolve regardless of module order.
pub fn resolve_nominal_bodies(self: &Checker, module: &Module, module_path: String) {
    self.current_module = Some(module_path)
    for i in 0..module.decls.len {
        let decl = &module.decls[i]
        resolve_one_body(self, decl, module_path)
    }
}

fn collect_one_name(self: &Checker, decl: &Decl, module_path: String) {
    decl.* match {
        Type(td) => {
            let fqn_owned = $"{module_path}.{td.name}"
            if self.nominals.contains(fqn_owned.as_view()) or self.aliases.contains(fqn_owned.as_view()) {
                push_diag_e(self, td.span, E_DUP_TYPE_DECL,
                    $"duplicate type declaration `{td.name}`")
                fqn_owned.deinit()
                return
            }
            // Decide nominal vs alias by inspecting the body. The
            // OwnedString is consumed by whichever registry takes it: the
            // nominal registry for struct/enum, the alias registry for an
            // alias body (stored unresolved for lazy expansion at use).
            let kind = nominal_kind_of(td.body)
            kind match {
                NkStruct => register_struct_placeholder(self, &td, fqn_owned),
                NkEnum => register_enum_placeholder(self, &td, fqn_owned),
                NkAlias => self.aliases.register(fqn_owned, td.body),
            }
        },
        _ => {},
    }
}

fn resolve_one_body(self: &Checker, decl: &Decl, module_path: String) {
    decl.* match {
        Type(td) => {
            let kind = nominal_kind_of(td.body)
            kind match {
                NkStruct => resolve_struct_body(self, &td, module_path),
                NkEnum => resolve_enum_body(self, &td, module_path),
                NkAlias => {},
            }
        },
        _ => {},
    }
}

type Nk = enum {
    NkStruct
    NkEnum
    NkAlias
}

fn nominal_kind_of(body: TypeExpr) Nk {
    return body match {
        AnonStruct(_) => Nk.NkStruct,
        AnonEnum(_) => Nk.NkEnum,
        _ => Nk.NkAlias,
    }
}

fn register_struct_placeholder(self: &Checker, td: &TypeDecl, fqn: OwnedString) {
    let empty_params: List(VarId) = list(0, self.allocator)
    let empty_fields: List(Field) = list(0, self.allocator)
    // `fqn` field is a placeholder - `register` overwrites it with the
    // stable view it owns. The OwnedString is transferred to the registry.
    let sd = StructDef {
        fqn = "",
        module = self.current_module.unwrap(),
        is_pub = td.is_pub,
        type_params = empty_params,
        fields = empty_fields,
        decl_span = td.span,
        deprecation = null,
        is_simd = false,
        is_foreign = false,
    }
    let _r = self.nominals.register(NominalDef.NomStruct(sd), fqn)
}

fn register_enum_placeholder(self: &Checker, td: &TypeDecl, fqn: OwnedString) {
    let empty_params: List(VarId) = list(0, self.allocator)
    let empty_variants: List(VariantDef) = list(0, self.allocator)
    let ed = EnumDef {
        fqn = "",
        module = self.current_module.unwrap(),
        is_pub = td.is_pub,
        type_params = empty_params,
        variants = empty_variants,
        tag_values = null,
        decl_span = td.span,
        deprecation = null,
    }
    let _r = self.nominals.register(NominalDef.NomEnum(ed), fqn)
}

fn resolve_struct_body(self: &Checker, td: &TypeDecl, module_path: String) {
    let fqn_owned = $"{module_path}.{td.name}"
    let id_opt = self.nominals.lookup_fqn(fqn_owned.as_view())
    fqn_owned.deinit()
    if id_opt.is_none() { return }
    let id = id_opt.unwrap()

    let anon_opt = td.body match {
        AnonStruct(a) => Some(a),
        _ => null,
    }
    if anon_opt.is_none() { return }
    let anon = anon_opt.unwrap()

    // Bind generics into a fresh scope so field type-exprs can see them.
    self.env.push_scope()
    let type_params: List(VarId) = list(anon.generics.len, self.allocator)
    for i in 0..anon.generics.len {
        let gp = &anon.generics[i]
        let fresh = self.engine.fresh_var()
        let id = fresh match { Var(v) => v.id, _ => 0u32 }
        type_params.push(id)
        self.env.bind(gp.name, Binding {
            scheme = mono(fresh, self.allocator),
            decl = node_id_of(gp.span),
            is_const = true,
            is_type_param = true,
        })
    }

    let fields: List(Field) = list(anon.fields.len, self.allocator)
    for i in 0..anon.fields.len {
        let f = &anon.fields[i]
        let ty = resolve_type_expr(self, f.type_expr)
        fields.push(Field { name = f.name, ty = ty })
    }
    self.env.pop_scope()

    // Re-write the registry entry with the resolved body.
    let existing = self.nominals.get(id)
    existing.* match {
        NomStruct(sd) => {
            let updated = StructDef {
                fqn = sd.fqn,
                module = sd.module,
                is_pub = sd.is_pub,
                type_params = type_params,
                fields = fields,
                decl_span = sd.decl_span,
                deprecation = sd.deprecation,
                is_simd = sd.is_simd,
                is_foreign = sd.is_foreign,
            }
            self.nominals.defs[id as usize] = NominalDef.NomStruct(updated)
        },
        _ => {},
    }
}

fn resolve_enum_body(self: &Checker, td: &TypeDecl, module_path: String) {
    let fqn_owned = $"{module_path}.{td.name}"
    let id_opt = self.nominals.lookup_fqn(fqn_owned.as_view())
    fqn_owned.deinit()
    if id_opt.is_none() { return }
    let id = id_opt.unwrap()

    let anon_opt = td.body match {
        AnonEnum(a) => Some(a),
        _ => null,
    }
    if anon_opt.is_none() { return }
    let anon = anon_opt.unwrap()

    self.env.push_scope()
    let type_params: List(VarId) = list(anon.generics.len, self.allocator)
    for i in 0..anon.generics.len {
        let gp = &anon.generics[i]
        let fresh = self.engine.fresh_var()
        let vid = fresh match { Var(v) => v.id, _ => 0u32 }
        type_params.push(vid)
        self.env.bind(gp.name, Binding {
            scheme = mono(fresh, self.allocator),
            decl = node_id_of(gp.span),
            is_const = true,
            is_type_param = true,
        })
    }

    let variants: List(VariantDef) = list(anon.variants.len, self.allocator)
    for i in 0..anon.variants.len {
        let v = &anon.variants[i]
        let payloads: List(Ty) = list(v.payloads.len, self.allocator)
        for j in 0..v.payloads.len {
            let p = &v.payloads[j]
            payloads.push(resolve_type_expr(self, p))
        }
        variants.push(VariantDef { name = v.name, payloads = payloads })
    }
    self.env.pop_scope()

    let existing = self.nominals.get(id)
    existing.* match {
        NomEnum(ed) => {
            let updated = EnumDef {
                fqn = ed.fqn,
                module = ed.module,
                is_pub = ed.is_pub,
                type_params = type_params,
                variants = variants,
                tag_values = null,
                decl_span = ed.decl_span,
                deprecation = ed.deprecation,
            }
            self.nominals.defs[id as usize] = NominalDef.NomEnum(updated)
        },
        _ => {},
    }
}

// ─────────────────────────────────────────────────────────────────────
// Phase 2 - collect function signatures
//
// Every `pub fn` and `fn` is registered with its polymorphic scheme
// before any body is checked. Forward references between functions in
// the same module just work; cross-module references depend on import
// visibility (out of scope for the first slice - visibility is
// "current module only").
// ─────────────────────────────────────────────────────────────────────

pub fn collect_signatures(self: &Checker, module: &Module, module_path: String) {
    self.current_module = Some(module_path)
    self.engine.set_nominal_registry(&self.nominals)

    for i in 0..module.decls.len {
        let decl = &module.decls[i]
        collect_one_signature(self, decl)
    }
}

fn collect_one_signature(self: &Checker, decl: &Decl) {
    decl.* match {
        Function(fd) => register_function_sig(self, &fd),
        Const(cd) => register_constant(self, &cd),
        _ => {},
    }
}

// A module-level constant registers its declared type in the signature
// pass; without an annotation it gets a fresh variable the body pass
// binds from the initializer. Uses in any module unify against the same
// entry, so cross-module reads work regardless of check order.
fn register_constant(self: &Checker, cd: &ConstDecl) {
    let ty = cd.type_annotation match {
        Some(t) => resolve_type_expr(self, &t),
        None => self.engine.fresh_var(),
    }
    let fqn = $"{self.current_module.unwrap()}.{cd.name}"
    self.constants.register(fqn, ty)
}

fn register_function_sig(self: &Checker, fd: &FunctionDecl) {
    self.sig_tps.clear()
    self.env.push_scope()
    self.engine.enter_level()

    let params: List(Ty) = list(fd.params.len, self.allocator)
    for i in 0..fd.params.len {
        let p = &fd.params[i]
        let ty = resolve_type_expr(self, &p.type_expr)
        params.push(ty)
    }
    let ret = fd.return_type match {
        Some(rt) => resolve_type_expr(self, &rt),
        None => Ty.Void,
    }
    let fn_ty = self.engine.mk_func(params, ret)

    self.engine.exit_level()
    let scheme = self.engine.generalize(fn_ty)
    self.env.pop_scope()

    // Trailing defaulted params and the variadic tail may be omitted at
    // call sites.
    let required = fd.params.len
    loop {
        if required == 0 { break }
        let p = &fd.params[required - 1]
        if p.default_value.is_none() and !p.is_variadic { break }
        required = required - 1
    }

    let scheme_obj = FunctionScheme {
        name = fd.name,
        signature = scheme,
        module = self.current_module,
        is_pub = fd.is_pub,
        is_foreign = is_foreign_directive(&fd.directives),
        required_params = required,
        has_variadic = fd.params.len > 0 and fd.params[fd.params.len - 1].is_variadic,
        decl_span = fd.span,
        deprecation = null,
        id = 0u32,           // filled in by registry.register
    }
    let id = self.functions.register(scheme_obj)

    // A generic signature also records its instantiation template: the
    // declaration plus the `$T` bindings `resolve_generic_bind` just
    // collected, in declaration order (M10). The list moves in; the
    // checker keeps a fresh one for the next signature.
    if scheme.quantified.len() > 0 {
        self.templates.set(id, GenericTemplate {
            decl = fd.*,
            module = self.current_module.unwrap(),
            tps = self.sig_tps,
        })
        self.sig_tps = list(0, self.allocator)
    }
}

// ─────────────────────────────────────────────────────────────────────
// Phase 3 - check function bodies
//
// For each function with a body, push the function's frame, push a
// scope for its parameters, walk the block expression, and unify the
// body's type against the declared return.
//
// Body inference is in `checker_expr.f` / `checker_stmt.f`; this file
// only orchestrates.
// ─────────────────────────────────────────────────────────────────────

pub fn check_module_bodies(self: &Checker, module: &Module, module_path: String) {
    self.current_module = Some(module_path)

    for i in 0..module.decls.len {
        let decl = &module.decls[i]
        check_one_decl(self, decl)
    }
}

fn check_one_decl(self: &Checker, decl: &Decl) {
    decl.* match {
        Function(fd) => {
            // A generic template's body is only validated per
            // instantiation (M10) - with unbound type params, overload
            // resolution is unreliable and node types are meaningless.
            // An uninstantiated template is never checked at all.
            if !declares_generic(&fd) { check_function_body(self, &fd) }
        },
        Const(cd) => check_constant_init(self, &cd),
        _ => {},
    }
}

fn check_constant_init(self: &Checker, cd: &ConstDecl) {
    let fqn = $"{self.current_module.unwrap()}.{cd.name}"
    let reg = self.constants.get_fqn(fqn.as_view())
    fqn.deinit()
    let v = check_expr(self, &cd.value)
    unify_expected(self, v, reg.unwrap(), E_TYPE_MISMATCH, cd.span)
}

fn check_function_body(self: &Checker, fd: &FunctionDecl) {
    if fd.body.is_none() { return }
    let body = fd.body.unwrap()

    self.env.push_scope()
    self.engine.enter_level()

    let params: List(Ty) = list(fd.params.len, self.allocator)
    for i in 0..fd.params.len {
        let p = &fd.params[i]
        let ty = resolve_type_expr(self, &p.type_expr)
        self.env.bind(p.name, Binding {
            scheme = mono(ty, self.allocator),
            decl = node_id_of(p.span),
            is_const = false,
            is_type_param = false,
        })
        params.push(ty)
    }
    let ret = fd.return_type match {
        Some(rt) => resolve_type_expr(self, &rt),
        None => Ty.Void,
    }

    let frame = FnFrame { name = fd.name, return_ty = ret, decl_span = fd.span }
    self.fn_stack.push(frame)

    let body_ty = check_block(self, &body)
    // Only the implicit-return path is checked here: a block whose final
    // expression is the function's value. A block that ends in an explicit
    // `return` yields Void and is covered by `check_return`, so Void is
    // skipped to avoid a spurious "expected T, got void". A void function
    // discards its trailing expression's value entirely.
    let ret_is_void = ret match { Void => true, _ => false }
    body_ty match {
        Void => {},
        _ => {
            if !ret_is_void {
                unify_expected(self, body_ty, ret, E_RETURN_MISMATCH, fd.span)
            }
        },
    }

    let _r =self.fn_stack.pop()
    self.engine.exit_level()
    self.env.pop_scope()
}

// ─────────────────────────────────────────────────────────────────────
// Phase 3.5 - generic specialization (M10)
//
// Every commit of a generic overload left a `PendingSpec` behind. Once
// the surrounding inference has settled, each pending pick either
// reuses an existing specialization (same template, same concrete
// signature) or instantiates one: the template body is re-checked -
// original AST, no clone - with its type params bound to the concrete
// arguments, recording into a private overlay of the result tables.
// The pick's node is then rewritten to cite the specialization, so
// lowering never sees a generic callee.
// ─────────────────────────────────────────────────────────────────────

// A chain of instantiations this deep is infinitely recursive
// polymorphism (each level must have a NEW concrete signature - plain
// self-recursion reuses its own key and never recurses here). The
// reference caps at 32 and skips silently; this reports.
const MAX_SPEC_DEPTH: usize = 64

// Drain the pending picks of the body scope that just finished.
// `process_pending` never appends to this list: picks recorded during a
// nested instantiation's body check land on that frame's own
// (swapped-in) list and drain there.
fn drain_pending_specs(self: &Checker) {
    for i in 0..self.pending_specs.len {
        let p = self.pending_specs[i]
        process_pending(self, &p)
    }
    self.pending_specs.clear()
}

fn process_pending(self: &Checker, p: &PendingSpec) {
    // The call site's instantiated signature, settled by now. Any var
    // still free means inference never pinned a type argument.
    let params: List(Ty) = list(p.inst_params.len, self.allocator)
    for i in 0..p.inst_params.len {
        params.push(self.engine.zonk(p.inst_params[i]))
    }
    let ret = self.engine.zonk(p.inst_ret)
    if !sig_concrete(self, &params, &ret) {
        let name = self.templates.get(p.function_id).unwrap().decl.name
        push_diag_e(self, p.span, E_UNINFERRED,
            $"cannot infer the type arguments of generic function `{name}` at this call site")
        params.deinit()
        return
    }

    let key = key_for(p.function_id, &params, ret, self.allocator)
    let existing = self.specs.lookup(key.as_view())
    let id = existing match {
        Some(sid) => {
            key.deinit()
            params.deinit()
            Some(sid)
        },
        None => instantiate(self, p, key, params, ret),
    }
    if id.is_none() { return }

    // Rewrite the pick's table entry so lowering calls the
    // specialization's symbol. `self.results` is the table set the pick
    // was recorded into - the program tables at top level, the owning
    // instantiation's overlay during a nested drain.
    let node = node_id_of(p.span)
    if p.is_operator {
        let cur = self.results.resolved_ops.get(node)
        if cur.is_some() {
            let op = cur.unwrap()
            self.results.record_operator(node, with_spec(&op, id.unwrap()))
        }
    } else {
        self.results.record_target(node, ResolvedTarget.RtSpecialized(id.unwrap()))
    }
}

// Unify every parked anonymous literal's field initializers against its
// now-known nominal's declared field types. Reverse insertion order so
// an outer literal's unifications bind the vars its nested literals
// need (literals check bottom-up, so inner entries were pushed first).
// A literal whose var never resolved to a struct is left alone - its
// unpinned numeric fields fall through to `validate_literals`.
fn resolve_anon_literals(self: &Checker) {
    let i = self.pending_anons.len
    while i > 0 {
        i = i - 1
        let pa = &self.pending_anons[i]
        let z = self.engine.zonk(pa.ty)
        for k in 0..pa.fields.len {
            let rec = &pa.fields[k]
            let fty = struct_field_lookup(self, &z, rec.name)
            if fty.is_some() {
                const o = self.engine.unify(rec.ty, fty.unwrap())
                report_unify(self, &o, E_TYPE_MISMATCH, rec.span)
            }
        }
    }
    self.pending_anons.clear()
}

// Report every unsuffixed numeric literal whose var never resolved.
// Runs after the specialization drain so literals inside instantiated
// template bodies (whose vars bound during the re-check) count as
// resolved; the engine's bindings are global, so one sweep covers the
// program tables and every overlay alike.
fn validate_literals(self: &Checker) {
    for i in 0..self.pending_literals.len {
        let pl = &self.pending_literals[i]
        let z = self.engine.zonk(pl.ty)
        let unresolved = z match { Var(_) => true, _ => false }
        if unresolved {
            let kind = if pl.is_float { "float" } else { "integer" }
            push_diag_e(self, pl.span, E_UNINFERRED,
                $"Cannot determine concrete type for {kind} literal `{pl.text}`")
        }
    }
}

// No free type variable anywhere in the instantiated signature.
fn sig_concrete(self: &Checker, params: &List(Ty), ret: &Ty) bool {
    let q: Set(VarId) = set(self.allocator)
    for i in 0..params.len {
        free_vars(&params[i], 0u32, &q)
    }
    free_vars(ret, 0u32, &q)
    let n = q.len()
    q.deinit()
    return n == 0
}

// Register and check one new specialization. Registration happens
// BEFORE the body re-check so a self-recursive generic resolves to its
// own key instead of recursing forever. Returns null (with a
// diagnostic) when the instantiation chain is implausibly deep.
fn instantiate(self: &Checker, p: &PendingSpec, key: OwnedString, params: List(Ty), ret: Ty) u32? {
    if self.spec_depth >= MAX_SPEC_DEPTH {
        push_diag_e(self, p.span, E_UNINFERRED,
            from_view("generic instantiation exceeds the depth limit - infinitely recursive polymorphism?"))
        key.deinit()
        params.deinit()
        return null
    }
    // The pick's id came from the function registry; a generic scheme
    // without a template entry is a compiler bug, not an input error.
    let template = self.templates.get(p.function_id).unwrap()

    let sid = self.specs.register(Specialization {
        id = 0u32,               // assigned by register
        function_id = p.function_id,
        key = key,
        name = template.decl.name,
        module = template.module,
        decl = template.decl,
        concrete_params = params,
        concrete_return = ret,
        overlay = inference_results(self.allocator),
    })

    // The re-check runs in the template's own context: its module for
    // name resolution (unioned with the caller chain - see
    // `current_visibility`), a fresh overlay for the result tables, and
    // a fresh pending list so nested generic picks drain inside this
    // frame, while the overlay is still the active table set.
    let saved_results = self.results
    let saved_pending = self.pending_specs
    let saved_anons = self.pending_anons
    let saved_module = self.current_module
    self.results = inference_results(self.allocator)
    self.pending_specs = list(0, self.allocator)
    self.pending_anons = list(0, self.allocator)
    self.current_module = Some(template.module)
    self.spec_callers.push(p.caller_module)
    self.spec_depth = self.spec_depth + 1

    // Bind each signature type param to its concrete argument; the
    // body's `$T` / `T` occurrences resolve to these instead of minting
    // fresh vars.
    self.env.push_scope()
    for i in 0..template.tps.len {
        let bound = p.tp_binds.get(template.tps[i].var_id)
        let conc = bound match {
            Some(b) => self.engine.zonk(b),
            None => Ty.Error,
        }
        self.env.bind(template.tps[i].name, Binding {
            scheme = mono(conc, self.allocator),
            decl = node_id_of(template.decl.span),
            is_const = true,
            is_type_param = true,
        })
    }

    check_function_body(self, &template.decl)
    resolve_anon_literals(self)
    drain_pending_specs(self)

    self.env.pop_scope()
    self.spec_depth = self.spec_depth - 1
    let _c = self.spec_callers.pop()

    // The shared final zonk only walks the program tables; the overlay
    // zonks here, while the engine is live.
    let zonked: Dict(NodeId, Ty) = dict(self.allocator)
    for entry in self.results.node_types {
        zonked.set(entry.key, self.engine.zonk(entry.value))
    }
    self.results.replace_node_types(zonked)

    let overlay = self.results
    self.results = saved_results
    self.pending_specs = saved_pending
    self.pending_anons = saved_anons
    self.current_module = saved_module

    // RTTI instantiations surface program-wide, not per overlay.
    self.results.merge_instantiated(&overlay)

    self.specs.set_overlay(sid, overlay)
    return Some(sid)
}

// ─────────────────────────────────────────────────────────────────────
// Expression / statement inference - minimal subset.
//
// First slice covers: literals, identifiers, binary primitive ops on
// matching numeric types, calls (direct lookup against
// `FunctionRegistry`), `let` statements, `return`, block expressions.
// More advanced forms (match, lambdas, member access, generics
// dispatch) layer on top in follow-up patches.
// ─────────────────────────────────────────────────────────────────────

pub fn check_expr(self: &Checker, expr: &Expr) Ty {
    let ty = check_expr_kind(self, expr)
    self.results.record_type(node_id_of(expr_span(expr)), ty)
    return ty
}

fn check_expr_kind(self: &Checker, expr: &Expr) Ty {
    return expr.* match {
        Lit(lit) => check_literal(self, &lit),
        Identifier(id) => check_identifier(self, &id),
        Block(blk) => check_block(self, &blk),
        Binary(bin) => check_binary(self, &bin),
        Call(call) => check_call(self, &call),
        If(if_expr) => check_if(self, &if_expr),
        StructLit(lit) => check_struct_lit(self, &lit),
        MemberAccess(ma) => check_member(self, &ma),
        TupleLit(t) => check_tuple_lit(self, &t),
        Cast(c) => check_cast(self, &c),
        Assignment(a) => check_assignment(self, &a),
        AddressOf(a) => check_address_of(self, &a),
        Dereference(d) => check_deref(self, &d),
        Match(m) => check_match(self, &m),
        Index(ix) => check_index(self, &ix),
        Range(r) => check_range(self, &r),
        Unary(u) => check_unary(self, &u),
        Coalesce(co) => check_coalesce(self, &co),
        Try(tr) => check_try(self, &tr),
        InterpolatedString(is) => check_interpolation(self, &is),
        ArrayLit(al) => check_array_literal(self, &al),
        _ => self.engine.fresh_var(),
    }
}

// `[a, b, c]` and `[v; N]`. Elements unify to one type; the node types
// as `[T; len]`. A repeat count must be a plain integer literal - the
// only form the corpus writes - any other count expression leaves the
// node untyped (fresh var), the pre-M10 behavior for unsizable shapes.
fn check_array_literal(self: &Checker, al: &ArrayLiteralExpr) Ty {
    return al.kind match {
        Elements(es) => {
            if es.len == 0 { return self.engine.mk_array(self.engine.fresh_var(), 0) }
            let elem = check_expr(self, &es[0])
            for i in 1..es.len {
                let t = check_expr(self, &es[i])
                unify_expected(self, t, elem, E_TYPE_MISMATCH, expr_span(&es[i]))
            }
            self.engine.mk_array(elem, es.len)
        },
        Repeat(r) => {
            let elem = check_expr(self, r.value)
            let n = literal_count_of(r.count)
            n match {
                Some(len) => self.engine.mk_array(elem, len),
                None => self.engine.fresh_var(),
            }
        },
    }
}

// The compile-time value of a repeat count written as a plain decimal
// integer literal; null for any other expression.
fn literal_count_of(e: &Expr) usize? {
    let lit = e.* match { Lit(l) => l, _ => return null }
    let il = lit.value match { Int(v) => v, _ => return null }
    return parse_decimal(il.text)
}

// Plain decimal digits (underscore separators allowed) to a usize;
// null for anything else.
fn parse_decimal(s: String) usize? {
    if s.len == 0 { return null }
    let n: usize = 0
    for i in 0..s.len {
        let c = s[i]
        if c == '_' { continue }
        if c < '0' or c > '9' { return null }
        n = n * 10 + ((c as usize) - 48)
    }
    return Some(n)
}

// String interpolation (RFC-004): desugar to StringBuilder calls, exactly
// as the reference checker does - the feature is stdlib-dependent by
// design. The desugar is synthesized as real AST and checked through the
// ordinary machinery, so overload resolution picks each `append` (and the
// format-spec fallback), the picks land on the synthetic nodes' ids, and
// the result type is whatever `to_string` returns - resolved, not
// assumed. The block is stored in `results.desugars` keyed by the
// interpolation node; lowering replays it instead of the original node.
//
//   $"a{x}b"       => { let __interp_sb_N = string_builder(0, null)
//                       defer __interp_sb_N.deinit()
//                       __interp_sb_N.append("a")
//                       __interp_sb_N.append(x)
//                       __interp_sb_N.append("b")
//                       __interp_sb_N.to_string() }
//   $sb"a{x}"      => { sb.append("a") sb.append(x) }        (void)
//
// The deferred deinit is a no-op on the happy path (`to_string`
// transfers ownership and zeroes the builder) and frees the buffer
// when a hole's expression escapes early (`$"{f()?}"`).
//
// `$(…)` constructor args map onto `string_builder(capacity, allocator)`
// at FULL arity - the defaults are spelled out as `0` / `null`, so the
// desugared call never leans on defaulted-argument materialization,
// which lowering does not do yet. A lone `&alloc` argument routes to the
// allocator slot wrapped in `Some(...)` (no implicit T -> Option(T)).
//
fn check_interpolation(self: &Checker, interp: &InterpolatedStringExpr) Ty {
    return interp.target match {
        NewString(args) => check_interp_owned(self, interp, &args),
        IntoBuilder(t) => check_interp_into(self, interp, t),
    }
}

fn check_interp_owned(self: &Checker, interp: &InterpolatedStringExpr, given: &List(Expr)) Ty {
    // The synthesized AST stores the name as a view; the buffer parks
    // with the result tables, which the desugar shares a lifetime with.
    const name = self.results.add_synth_string(fresh_builder_name(self))
    let stmts: List(Stmt) = list(interp.parts.len + 1, self.allocator)

    const ctor = synth_free_call(self, "string_builder", builder_ctor_args(self, given))
    stmts.push(Stmt.Let(LetStmt {
        span = synth_span(self),
        is_const = false,
        name = name,
        type_annotation = null,
        init = Some(ctor),
    }))
    let no_args: List(CallArgument) = list(0, self.allocator)
    stmts.push(Stmt.Defer(DeferStmt {
        span = synth_span(self),
        expr = synth_method_call(self, name, "deinit", no_args),
    }))
    push_append_stmts(self, &stmts, name, interp)

    let empty_args: List(CallArgument) = list(0, self.allocator)
    const done = synth_method_call(self, name, "to_string", empty_args)
    let block = box(or_global(self.allocator), BlockExpr {
        span = synth_span(self),
        stmts = stmts,
        trailing = Some(synth_box(self, done)),
    })
    const ty = check_block(self, block)
    self.results.record_desugar(node_id_of(interp.span), block)
    return ty
}

// `$sb"…"` - append each part into the existing builder; void. The
// parser only produces an identifier target; anything else is visited
// so errors report, but gets no desugar (lowering refuses the node).
fn check_interp_into(self: &Checker, interp: &InterpolatedStringExpr, target: &Expr) Ty {
    let tname = ""
    target.* match {
        Identifier(ide) => { tname = ide.name },
        _ => {},
    }
    if tname.len == 0 {
        let _t = check_expr(self, target)
        for i in 0..interp.parts.len {
            interp.parts[i] match {
                Hole(h) => { let _h = check_expr(self, h.expr) },
                Text(_) => {},
            }
        }
        return Ty.Void
    }

    let stmts: List(Stmt) = list(interp.parts.len, self.allocator)
    push_append_stmts(self, &stmts, tname, interp)
    let block = box(or_global(self.allocator), BlockExpr {
        span = synth_span(self),
        stmts = stmts,
        trailing = null,
    })
    const ty = check_block(self, block)
    self.results.record_desugar(node_id_of(interp.span), block)
    return ty
}

// One `NAME.append(part)` statement per non-empty part. A hole with a
// format spec passes it as a trailing String argument - overload
// resolution finds the spec-taking `append`.
fn push_append_stmts(self: &Checker, stmts: &List(Stmt), name: String, interp: &InterpolatedStringExpr) {
    for i in 0..interp.parts.len {
        interp.parts[i] match {
            Text(t) => {
                if t.len > 0 {
                    let args: List(CallArgument) = list(1, self.allocator)
                    const lit = synth_string_lit(self, segment_literal_text(self, t))
                    args.push(CallArgument.Positional(synth_box(self, lit)))
                    push_expr_stmt(self, stmts, synth_method_call(self, name, "append", args))
                }
            },
            Hole(h) => {
                let args: List(CallArgument) = list(2, self.allocator)
                args.push(CallArgument.Positional(h.expr))
                h.format match {
                    Some(spec) => {
                        const slit = synth_string_lit(self,
                            self.results.add_synth_string(escape_backslashes(self, spec)))
                        args.push(CallArgument.Positional(synth_box(self, slit)))
                    },
                    None => {},
                }
                push_expr_stmt(self, stmts, synth_method_call(self, name, "append", args))
            },
        }
    }
}

fn push_expr_stmt(self: &Checker, stmts: &List(Stmt), e: Expr) {
    stmts.push(Stmt.Expression(ExpressionStmt { span = synth_span(self), expr = e }))
}

// `$(…)` args onto `string_builder(capacity, allocator)`, full arity.
fn builder_ctor_args(self: &Checker, given: &List(Expr)) List(CallArgument) {
    let cap: Expr? = null
    let alloc_arg: Expr? = null
    if given.len >= 1 {
        const first_is_addr = given[0] match { AddressOf(_) => true, _ => false }
        if given.len == 1 and first_is_addr {
            alloc_arg = Some(wrap_some(self, given[0]))
        } else {
            cap = Some(given[0])
        }
    }
    if given.len >= 2 {
        const second_is_addr = given[1] match { AddressOf(_) => true, _ => false }
        if second_is_addr {
            alloc_arg = Some(wrap_some(self, given[1]))
        } else {
            alloc_arg = Some(given[1])
        }
    }

    let out: List(CallArgument) = list(2, self.allocator)
    const cap_e = cap match { Some(e) => e, None => synth_int_lit(self, "0") }
    out.push(CallArgument.Positional(synth_box(self, cap_e)))
    const alloc_e = alloc_arg match { Some(e) => e, None => synth_null(self) }
    out.push(CallArgument.Positional(synth_box(self, alloc_e)))
    return out
}

fn wrap_some(self: &Checker, e: Expr) Expr {
    let args: List(CallArgument) = list(1, self.allocator)
    args.push(CallArgument.Positional(synth_box(self, e)))
    return synth_free_call(self, "Some", args)
}

// ── desugar synthesis helpers ────────────────────────────────────────

// A span no real AST node carries: `file_id = -2` marks checker-
// synthesized nodes, and the monotonic `start` keeps every synthetic
// node id unique (node ids pack (start, length, file_id) - node_id.f).
// Diagnostics raised on a synthetic node render without a real source
// location; hole expressions keep their own real spans, so user errors
// still point at user code.
fn synth_span(self: &Checker) SourceSpan {
    const n = self.next_synth
    self.next_synth = n + 1
    return SourceSpan { file_id = -2, start = n as usize, length = 0 }
}

// Synthesized nodes live as long as the check result - allocated on the
// global allocator and deliberately leaked with it.
fn synth_box(self: &Checker, e: Expr) &Expr {
    return box(or_global(self.allocator), e)
}

fn synth_ident(self: &Checker, name: String) Expr {
    return Expr.Identifier(IdentifierExpr { span = synth_span(self), name = name })
}

fn synth_int_lit(self: &Checker, text: String) Expr {
    const sp = synth_span(self)
    return Expr.Lit(LiteralExpr {
        span = sp,
        value = LiteralValue.Int(IntLiteral { span = sp, text = text, suffix = "" }),
    })
}

fn synth_null(self: &Checker) Expr {
    return Expr.Lit(LiteralExpr { span = synth_span(self), value = LiteralValue.Null })
}

fn synth_string_lit(self: &Checker, text: String) Expr {
    const sp = synth_span(self)
    return Expr.Lit(LiteralExpr {
        span = sp,
        value = LiteralValue.String(StringLiteral { span = sp, text = text }),
    })
}

// `recv_name.method(args)` as a UFCS call node.
fn synth_method_call(self: &Checker, recv_name: String, method: String, args: List(CallArgument)) Expr {
    const ma = Expr.MemberAccess(MemberAccessExpr {
        span = synth_span(self),
        receiver = synth_box(self, synth_ident(self, recv_name)),
        member = method,
    })
    return Expr.Call(CallExpr { span = synth_span(self), callee = synth_box(self, ma), args = args })
}

fn synth_free_call(self: &Checker, name: String, args: List(CallArgument)) Expr {
    return Expr.Call(CallExpr {
        span = synth_span(self),
        callee = synth_box(self, synth_ident(self, name)),
        args = args,
    })
}

fn fresh_builder_name(self: &Checker) OwnedString {
    const n = self.next_synth
    self.next_synth = n + 1
    let sb = string_builder(20, self.allocator)
    defer sb.deinit()
    sb.append("__interp_sb_")
    sb.append(n)
    return sb.to_string()
}

// A segment's bytes as string-literal text, such that lowering's
// string-literal decode yields exactly the segment's decoded bytes.
// Segments share the string escape vocabulary and add `{{` / `}}`
// doubling - so brace-free raw text passes through untouched, and
// braced text is decoded (decode_interp_segment) then re-escaped.
fn segment_literal_text(self: &Checker, raw: String) String {
    let has_brace = false
    for i in 0..raw.len {
        if raw[i] == '{' or raw[i] == '}' { has_brace = true }
    }
    if !has_brace { return raw }
    const decoded_opt = decode_interp_segment(raw, self.allocator)
    // Malformed escape - the lexer already reported it; keep the raw text.
    if decoded_opt.is_none() { return raw }
    let decoded = decoded_opt.unwrap()
    const out = self.results.add_synth_string(escape_backslashes(self, decoded.as_view()))
    decoded.deinit()
    return out
}

// Double every backslash so a later string-literal decode is the
// identity on the remaining bytes. Always hands ownership out - a
// clean input copies - so the caller decides where the buffer lives.
fn escape_backslashes(self: &Checker, s: String) OwnedString {
    let has = false
    for i in 0..s.len {
        if s[i] == '\\' { has = true }
    }
    if !has { return from_view(s, self.allocator) }
    let sb = string_builder(s.len + 4, self.allocator)
    defer sb.deinit()
    for i in 0..s.len {
        if s[i] == '\\' { sb.append_byte('\\') }
        sb.append_byte(s[i])
    }
    return sb.to_string()
}

// `scrutinee match { pat => body, ... }`. Each arm's pattern is checked
// against the scrutinee's type, its bindings live for that arm only, and
// every arm body unifies to one result type.
//
// Exhaustiveness is not checked here.
fn check_match(self: &Checker, m: &MatchExpr) Ty {
    let scrutinee = check_expr(self, m.scrutinee)
    // `Never` is the identity of the arm join - it takes the other side -
    // so the first arm sets the type and a match whose every arm diverges
    // stays `Never`. That is the honest answer: such a match has no value
    // to consume, and `Never` unifies with whatever the context wants.
    let result = Ty.Never
    for i in 0..m.arms.len {
        let arm = &m.arms[i]
        self.env.push_scope()
        check_pattern(self, &arm.pattern, scrutinee)
        arm.guard match {
            Some(g) => { let _g = check_expr(self, g) },
            None => {},
        }
        let body_ty = check_expr(self, arm.body)
        result = join_types(self, result, body_ty, E_ARM_MISMATCH, arm.span)
        self.env.pop_scope()
    }
    return result
}

// Check `pat` against `expected`, binding the variables it introduces into
// the current scope. Every sub-pattern is walked even when the shape can't
// be resolved, so a binding always exists - unconstrained beats absent,
// which would surface later as a bogus `unknown identifier`.
fn check_pattern(self: &Checker, pat: &Pattern, expected: Ty) {
    pat.* match {
        Wildcard(_) => {},
        Variable(v) => check_variable_pattern(self, &v, expected),
        Literal(l) => {
            let lt = literal_value_ty(self, l.value)
            unify_expected(self, lt, expected, E_TYPE_MISMATCH, l.span)
        },
        EnumVariant(ev) => check_variant_pattern(self, &ev, expected),
        Or(o) => check_or_pattern(self, &o, expected),
        Range(r) => {
            let bound = check_range_bounds(self, &r)
            unify_expected(self, bound, expected, E_TYPE_MISMATCH, r.span)
        },
        // Struct and tuple destructuring bind their sub-patterns but do not
        // yet constrain them against the scrutinee's field types.
        Struct(s) => check_struct_pattern(self, &s),
        Tuple(t) => bind_unconstrained(self, &t.elements),
        // The front end could not represent this pattern (or-patterns,
        // ranges, struct and tuple destructuring - see the projector). It
        // must be reported: left silent it is indistinguishable from a
        // wildcard, and the arm would match everything.
        Error(e) => push_diag_e(self, e.span, E_UNSUPPORTED_PATTERN,
            from_view("unsupported pattern form: or-patterns, ranges, and struct/tuple destructuring are not implemented yet")),
    }
}

fn check_or_pattern(self: &Checker, o: &OrPattern, expected: Ty) {
    for i in 0..o.alternatives.len {
        check_pattern(self, &o.alternatives[i], expected)
    }
}

fn check_struct_pattern(self: &Checker, s: &StructPattern) {
    for i in 0..s.fields.len {
        let f = &s.fields[i]
        f.binding match {
            Some(p) => check_pattern(self, p, self.engine.fresh_var()),
            None => bind_pattern_var(self, f.name, self.engine.fresh_var(), f.span),
        }
    }
}

fn bind_unconstrained(self: &Checker, pats: &List(Pattern)) {
    for i in 0..pats.len {
        check_pattern(self, &pats[i], self.engine.fresh_var())
    }
}

// `Some(x)` / `Color.Red` in pattern position. Resolves the variant against
// the scrutinee's enum, binds each payload sub-pattern to its declared type,
// and records `RtEnumVariant` on the pattern node so lowering can read the
// variant index without re-resolving - the same seam calls use for
// `RtFunction`.
fn check_variant_pattern(self: &Checker, ev: &EnumVariantPattern, expected: Ty) {
    let nr = self.engine.resolve(expected) match {
        Nominal(n) => Some(n),
        _ => null,
    }
    if nr.is_none() { bind_unconstrained(self, &ev.payloads); return }
    let n = nr.unwrap()

    let ed = self.nominals.get(n.id).* match {
        NomEnum(e) => Some(e),
        _ => null,
    }
    if ed.is_none() { bind_unconstrained(self, &ev.payloads); return }
    let e = ed.unwrap()

    let vnum = 0u32
    let found = false
    for i in 0..e.variants.len {
        if !found and e.variants[i].name == ev.name {
            vnum = i as u32
            found = true
        }
    }
    if !found { bind_unconstrained(self, &ev.payloads); return }
    self.results.record_target(node_id_of(ev.span), ResolvedTarget.RtEnumVariant(n.id, vnum))

    let payloads = &e.variants[vnum as usize].payloads
    if payloads.len != ev.payloads.len { bind_unconstrained(self, &ev.payloads); return }

    // Payload types are written against the enum's own type params; the
    // scrutinee's type arguments give them concrete meaning.
    let sub = dict(self.allocator)
    for k in 0..e.type_params.len {
        if k < n.args.len { sub.set(e.type_params[k], n.args[k]) }
    }
    for i in 0..payloads.len {
        let pty = substitute(&payloads[i], &sub, self.allocator)
        check_pattern(self, &ev.payloads[i], pty)
    }
    sub.deinit()
}

// A bare identifier in pattern position is either a binding or a
// payload-less enum variant (`None`, `Red`). Only scope tells them apart:
// if the scrutinee is an enum with a nullary variant of that name, the
// identifier names the variant. Otherwise it binds.
//
// Getting this backwards is silent: a variant read as a binding is
// irrefutable, so `c match { Red => 1, Green => 2 }` would always take the
// first arm. Lowering reads the decision back off the node as
// `RtEnumVariant`, so it never has to re-derive it.
fn check_variable_pattern(self: &Checker, v: &VariablePattern, expected: Ty) {
    let nr = self.engine.resolve(expected) match {
        Nominal(n) => Some(n),
        _ => null,
    }
    if nr.is_some() {
        let n = nr.unwrap()
        let idx = nullary_variant_index(self, n.id, v.name)
        if idx.is_some() {
            self.results.record_target(node_id_of(v.span), ResolvedTarget.RtEnumVariant(n.id, idx.unwrap()))
            return
        }
    }
    bind_pattern_var(self, v.name, expected, v.span)
}

// The index of `name` among `id`'s variants, when that variant carries no
// payload. Null when `id` is not an enum or has no such variant.
fn nullary_variant_index(self: &Checker, id: NominalId, name: String) u32? {
    let ed = self.nominals.get(id).* match {
        NomEnum(e) => Some(e),
        _ => null,
    }
    if ed.is_none() { return null }
    let e = ed.unwrap()
    for i in 0..e.variants.len {
        let vd = &e.variants[i]
        if vd.name == name and vd.payloads.len == 0 { return Some(i as u32) }
    }
    return null
}

fn bind_pattern_var(self: &Checker, name: String, ty: Ty, span: SourceSpan) {
    self.env.bind(name, Binding {
        scheme = mono(ty, self.allocator),
        decl = node_id_of(span),
        is_const = true,
        is_type_param = false,
    })
    // Lowering reads the binding's type off the pattern node.
    self.results.record_type(node_id_of(span), ty)
}

// `lhs = rhs` - an expression that yields no value. The right side must fit
// the left's type, so lowering can pick a store width from the destination.
//
// ponytail: a non-place left side (`f() = 1`) is still not rejected here;
// lowering refuses to emit the function instead of writing somewhere
// arbitrary, so the failure is loud but the diagnostic is not precise.
fn check_assignment(self: &Checker, a: &AssignmentExpr) Ty {
    let lhs = check_expr(self, a.lhs)
    let rhs = check_expr(self, a.rhs)
    unify_expected(self, rhs, lhs, E_TYPE_MISMATCH, a.span)
    return Ty.Void
}

// `&operand` - a reference to whatever the operand is.
fn check_address_of(self: &Checker, a: &AddressOfExpr) Ty {
    let inner = check_expr(self, a.operand)
    return self.engine.mk_ref(inner)
}

// `-x`, `!x`, `~x`. `!` fixes both sides to bool; `-` and `~` type as
// their operand, so a suffix-less literal operand stays open for the
// context to resolve. Numeric-ness of `-`/`~` operands is not enforced
// yet - rejection power lags the reference here (docs/self-host.md) -
// but the operand subtree is visited and the node gets a real type,
// which is what lowering's width/float decisions read.
fn check_unary(self: &Checker, u: &UnaryExpr) Ty {
    let inner = check_expr(self, u.operand)
    return u.op match {
        Not => {
            unify_expected(self, inner, Ty.Prim(PrimitiveKind.Bool), E_TYPE_MISMATCH, u.span)
            Ty.Prim(PrimitiveKind.Bool)
        },
        Neg => inner,
        BitNot => inner,
    }
}

// The `T` of an `Option(T)`, or null when `ty` is not the well-known
// Option nominal.
fn option_inner(self: &Checker, ty: &Ty) Ty? {
    let nr = ty.* match {
        Nominal(n) => n,
        _ => return null,
    }
    let id = self.nominals.by_fqn.get(FQN_OPTION)
    if id.is_none() { return null }
    if id.unwrap() != nr.id { return null }
    if nr.args.len != 1 { return null }
    return Some(nr.args[0])
}

// `a ?? b` - `a` must be `Option(T)`. Two result shapes, matching the
// reference checker: `Option(T) ?? Option(T)` chains and keeps the
// Option; `Option(T) ?? T` unwraps to `T`. The stdlib's `op_coalesce`
// overloads exist only for Option and are shadowed by these built-in
// paths, so no operator dispatch happens here (the reference resolves
// the same way).
fn check_coalesce(self: &Checker, c: &CoalesceExpr) Ty {
    let lhs = self.engine.resolve(check_expr(self, c.lhs))
    // Poison absorbs: the operand's error is already reported.
    let is_err = lhs match { Error => true, _ => false }
    if is_err {
        let _r = check_expr(self, c.rhs)
        return Ty.Error
    }
    let inner = option_inner(self, &lhs)
    if inner.is_none() {
        let _r = check_expr(self, c.rhs)
        push_diag_e(self, c.span, E_TYPE_MISMATCH,
            from_view("left operand of `??` must be an Option"))
        return self.engine.fresh_var()
    }
    let t = inner.unwrap()
    let rhs = check_expr(self, c.rhs)
    let rres = self.engine.resolve(rhs)
    let rinner = option_inner(self, &rres)
    if rinner.is_some() {
        unify_expected(self, rinner.unwrap(), t, E_TYPE_MISMATCH, c.span)
        return lhs
    }
    unify_expected(self, rhs, t, E_TYPE_MISMATCH, c.span)
    return t
}

// `expr?` (RFC-009). The reference desugars into a synthesized
// `op_try(expr) match { Continue(v) => v, Return(r) => return r }` AST
// and infers over that; node ids here are span-keyed, so synthesized
// nodes would collide with real ones. The shape is checked directly
// instead - resolve `op_try` against the operand, require its return to
// be `TryResult(T, R)`, take `T` as the expression's type, and unify `R`
// with the enclosing function's declared return - exactly what inference
// over the desugar concludes. The pick is recorded for lowering, which
// emits the call, the tag branch, and the early return itself.
fn check_try(self: &Checker, t: &TryExpr) Ty {
    let operand = check_expr(self, t.operand)
    if self.fn_stack.len == 0 {
        push_diag_e(self, t.span, E_TRY_OUTSIDE_FN,
            from_view("`?` operator outside of a function"))
        return self.engine.fresh_var()
    }

    let args: List(Ty) = list(1, self.allocator)
    args.push(operand)
    let pick = operator_pick(self, "op_try", &args, t.span)
    args.deinit()
    if pick.is_none() {
        push_diag_e(self, t.span, E_NO_OP_TRY,
            from_view("the `?` operator requires an `op_try` overload for the operand type"))
        return self.engine.fresh_var()
    }
    let p = pick.unwrap()

    let nr = self.engine.resolve(p.ret) match {
        Nominal(n) => Some(n),
        _ => null,
    }
    let tr_id = self.nominals.by_fqn.get(FQN_TRY_RESULT)
    let ok = nr.is_some() and tr_id.is_some()
    if ok { ok = nr.unwrap().id == tr_id.unwrap() and nr.unwrap().args.len == 2 }
    if !ok {
        push_diag_e(self, t.span, E_NO_OP_TRY,
            from_view("`op_try` must return `TryResult(T, R)`"))
        return self.engine.fresh_var()
    }
    let n = nr.unwrap()

    // The early-returned `R` must fit the enclosing function's declared
    // return type - the constraint the desugar's `return r` arm imposes.
    let frame = &self.fn_stack[self.fn_stack.len - 1]
    unify_expected(self, n.args[1], frame.return_ty, E_RETURN_MISMATCH, t.span)

    self.results.record_operator(node_id_of(t.span), ResolvedOperator {
        function_id = p.id, negate_result = false,
        cmp_derived_op = null, is_ref_form = false, spec_id = null,
    })
    note_pending(self, t.span, true, &p)
    return n.args[0]
}

// `operand.*` - peels one reference. A non-reference operand defers to a
// fresh var so an already-reported error does not cascade.
fn check_deref(self: &Checker, d: &DereferenceExpr) Ty {
    let t = self.engine.resolve(check_expr(self, d.operand))
    return t match {
        Ref(inner) => inner.*,
        _ => self.engine.fresh_var(),
    }
}

// `a..b` - a half-open `Range(T)`. Both bounds unify with each other, so
// `0..n` takes `n`'s type. A partial range (`a..`, `..b`, `..`) still has
// a `Range` type: the bound that is written fixes the element, and `..`
// leaves it free. Whether the missing bound can be supplied is the index
// site's problem, not the type's.
fn check_range(self: &Checker, r: &RangeExpr) Ty {
    let s = r.start match { Some(e) => Some(check_expr(self, e)), None => null }
    let e = r.end match { Some(x) => Some(check_expr(self, x)), None => null }
    let elem = s match {
        Some(st) => {
            e match {
                Some(en) => unify_expected(self, en, st, E_TYPE_MISMATCH, r.span),
                None => {},
            }
            st
        },
        None => e match {
            Some(en) => en,
            None => self.engine.fresh_var(),
        },
    }
    return mk_range(self, elem)
}

fn mk_range(self: &Checker, elem: Ty) Ty {
    let id = self.nominals.by_fqn.get(FQN_RANGE)
    if id.is_none() { return Ty.Error }
    let args: List(Ty) = list(1, self.allocator)
    args.push(elem)
    return Ty.Nominal(NominalRef { id = id.unwrap(), args = args })
}

fn mk_slice_ty(self: &Checker, elem: Ty) Ty {
    let id = self.nominals.by_fqn.get(FQN_SLICE)
    if id.is_none() { return Ty.Error }
    let args: List(Ty) = list(1, self.allocator)
    args.push(elem)
    return Ty.Nominal(NominalRef { id = id.unwrap(), args = args })
}

// True when `t` is the well-known `Range` nominal. An index of range type
// selects the slicing form of indexing rather than element access.
fn is_range_ty(self: &Checker, t: &Ty) bool {
    let n = t.* match { Nominal(nr) => nr, _ => return false }
    let id = self.nominals.by_fqn.get(FQN_RANGE)
    if id.is_none() { return false }
    return id.unwrap() == n.id
}

// The element of a built-in indexable base: a fixed array, or the
// well-known `Slice` nominal. Null for everything else, which routes the
// index through the user-defined operators.
fn builtin_element(self: &Checker, t: &Ty) Ty? {
    return t.* match {
        Array(a) => Some(a.elem.*),
        Nominal(n) => slice_element(self, &n),
        _ => null,
    }
}

fn slice_element(self: &Checker, n: &NominalRef) Ty? {
    let id = self.nominals.by_fqn.get(FQN_SLICE)
    if id.is_none() { return null }
    if id.unwrap() != n.id { return null }
    if n.args.len != 1 { return null }
    return Some(n.args[0])
}

// `base[index]`.
//
// Built-in array and slice indexing is tried BEFORE the user-defined
// operators, mirroring the reference checker. The order is not cosmetic:
// `String` and `Slice(u8)` coerce to each other in both directions, so
// `op_index(String, Range)` would otherwise capture `Slice(u8)[range]`.
//
// User types dispatch to one of two mutually exclusive operator shapes:
//   ref-form   `op_index_ref(&Self, Idx) &T` - a place: read, write, `&x[i]`
//   value-form `op_index(Self|&Self, Idx) T` - a computed read
// The winner is recorded on the index node with `is_ref_form` set, so
// lowering emits a call plus a load, or the call alone.
fn check_index(self: &Checker, idx: &IndexExpr) Ty {
    let base_ty = check_expr(self, idx.receiver)
    let index_ty = check_expr(self, idx.index)

    let rbase = self.engine.resolve(base_ty)
    let rindex = self.engine.resolve(index_ty)
    let ranged = is_range_ty(self, &rindex)

    if !ranged {
        let is_bool = rindex match { Prim(p) => p == PrimitiveKind.Bool, _ => false }
        if is_bool {
            push_diag_e(self, expr_span(idx.index), E_BAD_INDEX_TYPE,
                from_view("cannot use `bool` as an index type"))
            return self.engine.fresh_var()
        }
    }

    let elem = builtin_element(self, &rbase)
    if elem.is_some() {
        // `xs[a..b]` yields a view of the same element type; the bounds
        // are `usize`. `xs[i]` yields the element.
        if ranged {
            constrain_range_usize(self, &rindex, idx.span)
            return mk_slice_ty(self, elem.unwrap())
        }
        unify_expected(self, index_ty, ty_usize(), E_TYPE_MISMATCH, expr_span(idx.index))
        return elem.unwrap()
    }

    return user_index(self, idx, base_ty, &rbase, index_ty)
}

// A range used as an index counts in elements, so its bounds are `usize`.
fn constrain_range_usize(self: &Checker, rindex: &Ty, span: SourceSpan) {
    let n = rindex.* match { Nominal(nr) => nr, _ => return }
    if n.args.len != 1 { return }
    unify_expected(self, n.args[0], ty_usize(), E_TYPE_MISMATCH, span)
}

// User-defined indexing. Ref-form wins when it resolves; the reference
// checker additionally reports E2077 when a type declares both forms,
// which needs a non-committing probe of the loser and is not done here -
// the pick is the same either way, only the diagnostic is missing.
fn user_index(self: &Checker, idx: &IndexExpr, base_ty: Ty, rbase: &Ty, index_ty: Ty) Ty {
    // An unresolved base cannot arbitrate an overload set; committing the
    // first match would bind it arbitrarily.
    let base_unbound = rbase.* match { Var(_) => true, _ => false }
    if base_unbound { return self.engine.fresh_var() }

    let already_ref = rbase.* match { Ref(_) => true, _ => false }
    let ref_base = if already_ref { base_ty } else { self.engine.mk_ref(base_ty) }

    let ref_pick = index_operator(self, "op_index_ref", ref_base, index_ty, idx.span)
    if ref_pick.is_some() {
        let p = ref_pick.unwrap()
        // The declared return is `&T`; the expression's type is `T`.
        let inner = self.engine.resolve(p.ret) match {
            Ref(i) => i.*,
            _ => self.engine.fresh_var(),
        }
        self.results.record_operator(node_id_of(idx.span), ResolvedOperator {
            function_id = p.id, negate_result = false,
            cmp_derived_op = null, is_ref_form = true, spec_id = null,
        })
        note_pending(self, idx.span, true, &p)
        return inner
    }

    // Value form, tried against the base as written, as `&Self`, and -
    // for a reference base - against the pointee.
    let value_pick = index_operator(self, "op_index", base_ty, index_ty, idx.span)
    if value_pick.is_none() and !already_ref {
        value_pick = index_operator(self, "op_index", self.engine.mk_ref(base_ty), index_ty, idx.span)
    }
    if value_pick.is_none() and already_ref {
        let inner = rbase.* match { Ref(i) => i.*, _ => base_ty }
        value_pick = index_operator(self, "op_index", inner, index_ty, idx.span)
    }
    if value_pick.is_some() {
        let p = value_pick.unwrap()
        self.results.record_operator(node_id_of(idx.span), ResolvedOperator {
            function_id = p.id, negate_result = false,
            cmp_derived_op = null, is_ref_form = false, spec_id = null,
        })
        note_pending(self, idx.span, true, &p)
        return p.ret
    }

    push_diag_e(self, idx.span, E_NOT_INDEXABLE,
        from_view("type does not support indexing: declare `op_index_ref(&Self, Idx) &T` or `op_index(Self, Idx) T`"))
    return self.engine.fresh_var()
}

// Resolve one indexing operator against the visible registry candidates.
// Unlike a call site this must not report on failure - the caller tries
// several shapes and reports once at the end.
fn index_operator(self: &Checker, name: String, self_ty: Ty, index_ty: Ty, span: SourceSpan) OverloadPick? {
    let args: List(Ty) = list(2, self.allocator)
    args.push(self_ty)
    args.push(index_ty)
    let pick = operator_pick(self, name, &args, span)
    args.deinit()
    return pick
}

// Resolve one operator function (`op_index`, `op_try`, ...) against the
// visible registry candidates. Unlike a call site this must not report on
// failure - callers try several shapes, or supply their own diagnostic,
// and report once at the end.
fn operator_pick(self: &Checker, name: String, args: &List(Ty), span: SourceSpan) OverloadPick? {
    let vis = fn_visibility(self)
    let cands = self.functions.lookup(name, &vis) match {
        FnLookFound(c) => Some(c),
        _ => null,
    }
    if cands.is_none() { return null }
    let candidates = cands.unwrap()

    // Probe first: `resolve_overload` commits its unifications and reports
    // mismatches, so a losing shape would both pollute the substitution and
    // emit a diagnostic the caller is about to supersede.
    let viable = false
    for i in 0..candidates.len {
        if probe_candidate(self, &candidates[i], args).is_some() { viable = true }
    }
    let pick = if viable { resolve_overload(self, &candidates, args, span) } else { null }

    candidates.deinit()
    return pick
}

// `expr as T` yields `T`; cast validity (representability, pointer
// compatibility) is a later pass, matching the reference checker.
// A BARE numeric literal operand takes the target type directly -
// `0xFFFF_FFFF as u64` means a u64-typed constant, and without the pin
// the literal's var would go unresolved (E2001). Non-literal operands
// keep their own type; the cast converts.
fn check_cast(self: &Checker, c: &CastExpr) Ty {
    let v = check_expr(self, c.operand)
    let target = resolve_type_expr(self, c.target)
    let is_numeric_lit = c.operand.* match {
        Lit(l) => l.value match {
            Int(_) => true,
            Float(_) => true,
            _ => false,
        },
        _ => false,
    }
    if is_numeric_lit {
        // Best-effort: a numeric target binds the literal; a failure
        // (casting a literal to a pointer, say) is the cast's business,
        // not a unification diagnostic.
        let _o = self.engine.unify(v, target)
    }
    return target
}

// `()` is unit - the empty tuple and `void` are the same type.
fn check_tuple_lit(self: &Checker, t: &TupleLiteralExpr) Ty {
    if t.elements.len == 0 { return Ty.Void }
    let elems = list(t.elements.len, self.allocator)
    for i in 0..t.elements.len {
        let e = &t.elements[i]
        elems.push(check_expr(self, e))
    }
    return Ty.Tuple(elems)
}

fn check_literal(self: &Checker, lit: &LiteralExpr) Ty {
    return literal_value_ty(self, lit.value)
}

// The type of a literal form. Shared with pattern checking, where the same
// seven forms appear without an enclosing expression node.
fn literal_value_ty(self: &Checker, value: LiteralValue) Ty {
    return value match {
        Int(il) => numeric_literal_ty(self, il.span, il.suffix, il.text, false),
        Float(fl) => numeric_literal_ty(self, fl.span, fl.suffix, fl.text, true),
        Bool(_) => Ty.Prim(PrimitiveKind.Bool),
        String(_) => string_type(self),
        Char(_) => Ty.Prim(PrimitiveKind.Char),
        Byte(_) => Ty.Prim(PrimitiveKind.U8),
        Null => option_of_fresh(self),
    }
}

// A suffixed numeric literal IS its suffix's primitive; an unsuffixed one
// is a fresh var the context resolves, recorded so `validate_literals`
// can report the ones nothing ever pinned (E2001, as in the reference)
// instead of letting an unresolved var drift into lowering.
fn numeric_literal_ty(self: &Checker, span: SourceSpan, suffix: String, text: String, is_float: bool) Ty {
    if suffix.len > 0 {
        let p = prim_from_name(suffix)
        if p.is_some() { return Ty.Prim(p.unwrap()) }
    }
    let v = self.engine.fresh_var()
    self.pending_literals.push(PendingLit { span = span, ty = v, text = text, is_float = is_float })
    return v
}

fn string_type(self: &Checker) Ty {
    let id = self.nominals.by_fqn.get(FQN_STRING)
    if id.is_none() { return Ty.Error }
    let empty: List(Ty) = list(0, self.allocator)
    return Ty.Nominal(NominalRef { id = id.unwrap(), args = empty })
}

fn option_of_fresh(self: &Checker) Ty {
    let id = self.nominals.by_fqn.get(FQN_OPTION)
    if id.is_none() { return Ty.Error }
    let args: List(Ty) = list(1, self.allocator)
    args.push(self.engine.fresh_var())
    return Ty.Nominal(NominalRef { id = id.unwrap(), args = args })
}

fn check_identifier(self: &Checker, id: &IdentifierExpr) Ty {
    let b = self.env.lookup(id.name)
    if b.is_some() {
        let binding = b.unwrap()
        self.results.record_target(node_id_of(id.span), ResolvedTarget.RtLocal(binding.decl))
        return self.engine.specialize(&binding.scheme)
    }

    // Try function registry.
    let vis = fn_visibility(self)
    let look = self.functions.lookup(id.name, &vis)
    let found: List(FunctionScheme)? = look match {
        FnLookFound(candidates) => Some(candidates),
        _ => null,
    }
    if found.is_some() {
        let candidates = found.unwrap()
        if candidates.len == 1 {
            let c = &candidates[0]
            self.results.record_target(node_id_of(id.span),
                ResolvedTarget.RtFunction(c.id))
            return self.engine.specialize(&c.signature)
        }
        // Multiple overloads as a value - needs context to pick.
        return self.engine.fresh_var()
    }

    // Module-level constant?
    let cty = self.constants.lookup(id.name, &vis)
    if cty.is_some() { return cty.unwrap() }

    // Bare payload-less variant (`None`) - locals and functions win first.
    let vid = self.nominals.lookup_variant(id.name, 0usize, &vis)
    if vid.is_some() {
        let vt = construct_nullary(self, vid.unwrap(), id.name, id.span)
        if vt.is_some() { return vt.unwrap() }
    }

    // Bare type name in value position (`size_of(ArenaPage)`, `Type(u8)`):
    // the identifier types as the named type itself; the `Type(T)` coercion
    // lifts it where a reified type parameter expects it.
    let prim = prim_from_name(id.name)
    if prim.is_some() { return Ty.Prim(prim.unwrap()) }
    let tn = self.nominals.lookup(id.name, &vis) match {
        NomLookFound(n) => Some(n),
        _ => null,
    }
    if tn.is_some() { return nominal_with_fresh_args(self, tn.unwrap()) }

    push_diag_e(self, id.span, E_UNKNOWN_IDENT,
        $"unknown identifier `{id.name}`")
    return Ty.Error
}

fn nominal_with_fresh_args(self: &Checker, id: NominalId) Ty {
    let n = self.nominals.get(id).* match {
        NomStruct(s) => s.type_params.len,
        NomEnum(e) => e.type_params.len,
    }
    let args = list(n, self.allocator)
    for k in 0..n { args.push(self.engine.fresh_var()) }
    return Ty.Nominal(NominalRef { id = id, args = args })
}

fn check_block(self: &Checker, blk: &BlockExpr) Ty {
    self.env.push_scope()
    // A block containing a diverging statement produces no value: `never`
    // is the bottom type and unifies with anything, so a `match` arm or `if`
    // branch that returns does not drag the result type to `void`. Without
    // it, `x match { A => return 1, B => false }` types as void and a
    // `bool`-returning function rejects its own body.
    //
    // ponytail: divergence is tracked per statement, so an `if` whose every
    // branch returns is not itself treated as diverging. Add that when a
    // case needs it - it is a strictly larger analysis, not a different one.
    let diverges = false
    for i in 0..blk.stmts.len {
        let stmt = &blk.stmts[i]
        if check_stmt(self, stmt) { diverges = true }
    }
    let final_ty = blk.trailing match {
        Some(e) => check_expr(self, e),
        None => Ty.Void,
    }
    self.env.pop_scope()
    if diverges { return Ty.Never }
    return final_ty
}

// An expression statement discards its value; statement ifs get their
// own inference (branch types need not agree, mirroring the reference
// checker's statement-context if handling).
// Returns whether the statement diverges - `return`, `break` and
// `continue` transfer control away, so nothing after them is reached and
// the enclosing block produces no value.
fn check_stmt(self: &Checker, stmt: &Stmt) bool {
    stmt.* match {
        Let(ls) => check_let(self, &ls),
        Expression(es) => {
            let handled = es.expr match {
                If(ife) => {
                    check_if_stmt(self, &ife)
                    self.results.record_type(node_id_of(expr_span(&es.expr)), Ty.Void)
                    true
                },
                _ => false,
            }
            if !handled { let _r = check_expr(self, &es.expr) }
        },
        Return(rs) => { check_return(self, &rs); return true },
        Break(_) => return true,
        Continue(_) => return true,
        For(fs) => check_for(self, &fs),
        While(ws) => {
            let _c = check_expr(self, ws.condition)
            let _b = check_block(self, &ws.body)
        },
        Loop(ls) => { let _b = check_block(self, &ls.body) },
        Defer(ds) => { let _e = check_expr(self, &ds.expr) },
        _ => {},
    }
    return false
}

// `for name in iterable { body }`. The loop variable is bound for the
// body's scope only. A range yields its bound type; any other iterable
// needs the iterator protocol, so the variable stays an unconstrained var
// rather than being wrongly constrained.
fn check_for(self: &Checker, fs: &ForStmt) {
    let elem = check_iterable_element(self, fs.iterable)
    self.env.push_scope()
    self.env.bind(fs.var_name, Binding {
        scheme = mono(elem, self.allocator),
        decl = node_id_of(fs.span),
        is_const = true,
        is_type_param = false,
    })
    let _b = check_block(self, &fs.body)
    self.env.pop_scope()
}

fn check_iterable_element(self: &Checker, iterable: &Expr) Ty {
    return iterable.* match {
        Range(r) => check_range_bounds(self, &r),
        _ => {
            let _i = check_expr(self, iterable)
            self.engine.fresh_var()
        },
    }
}

fn check_range_bounds(self: &Checker, r: &RangeExpr) Ty {
    return unify_range_bounds(self, r.start, r.end, r.span)
}

fn check_range_bounds(self: &Checker, r: &RangePattern) Ty {
    return unify_range_bounds(self, r.start, r.end, r.span)
}

// Both bounds of a range share one type; that is its element type. The
// expression and pattern forms are separate AST types with identical shape
// (the grammar restricts where each may appear), so both funnel here.
fn unify_range_bounds(self: &Checker, start: &Expr?, end: &Expr?, span: SourceSpan) Ty {
    let elem = self.engine.fresh_var()
    start match {
        Some(e) => { unify_expected(self, check_expr(self, e), elem, E_TYPE_MISMATCH, span) },
        None => {},
    }
    end match {
        Some(e) => { unify_expected(self, check_expr(self, e), elem, E_TYPE_MISMATCH, span) },
        None => {},
    }
    return elem
}

// Statement-context if: branches unify only when they agree - a mismatch
// is silently void, never an error.
fn check_if_stmt(self: &Checker, if_expr: &IfExpr) {
    let _c = check_expr(self, if_expr.condition)
    let then_ty = check_block(self, &if_expr.then_branch)
    if_expr.else_branch match {
        NoElse => {},
        Block(b) => {
            let else_ty = check_block(self, &b)
            let probe = self.engine.try_unify(then_ty, else_ty)
            if probe.is_ok() { let _o = self.engine.unify(then_ty, else_ty) }
        },
        If(nested) => check_if_stmt(self, nested),
    }
}

fn check_let(self: &Checker, ls: &LetStmt) {
    let annotated = ls.type_annotation match {
        Some(t) => Some(resolve_type_expr(self, &t)),
        None => null,
    }
    let inferred = ls.init match {
        Some(e) => Some(check_expr(self, &e)),
        None => null,
    }
    let bound_ty = annotated match {
        Some(a) => {
            inferred match {
                Some(i) => { unify_expected(self, i, a, E_TYPE_MISMATCH, ls.span); a },
                None => a,
            }
        },
        None => inferred match {
            Some(i) => i,
            None => self.engine.fresh_var(),
        },
    }
    // Lowering reads the binding's type off this node. `let x` with neither
    // annotation nor initializer is legal - the type comes from later use -
    // so the annotation is not the source of truth and lowering must not
    // re-derive one from it.
    self.results.record_type(node_id_of(ls.span), bound_ty)
    self.env.bind(ls.name, Binding {
        scheme = mono(bound_ty, self.allocator),
        decl = node_id_of(ls.span),
        is_const = ls.is_const,
        is_type_param = false,
    })
}

fn unify_expected(self: &Checker, inferred: Ty, annotated: Ty, code: String, span: SourceSpan) {
    const o = self.engine.unify(inferred, annotated)
    report_unify(self, &o, code, span)
}

// Join two branch types: match arms, if/else branches.
//
// Distinct from `unify_expected`, where one side is the slot and the other
// flows into it. Here neither side is the slot, so coercion is tried in
// both directions and the *result* is the joined type rather than one of
// the inputs. Without that, arm order decides the answer: `T` then `null`
// would fix the type at `T` and reject the `null`.
//
// `Never` is the identity - it takes the other side - which is how a
// diverging arm stays out of the join entirely.
fn join_types(self: &Checker, a: Ty, b: Ty, code: String, span: SourceSpan) Ty {
    let forward = self.engine.try_unify(a, b).is_ok()
    const o = if forward {
        self.engine.unify(a, b)
    } else {
        self.engine.unify(b, a)
    }
    report_unify(self, &o, code, span)
    return o match {
        Unified(u) => u.ty,
        // The branches have no common type, and `report_unify` has just said
        // so. `Error` is the engine's poison: it absorbs into anything
        // silently, so the one diagnostic does not cascade into every later
        // use of the result. Returning one of the operands instead would
        // carry a type the program does not actually have.
        _ => Ty.Error,
    }
}

fn check_return(self: &Checker, rs: &ReturnStmt) {
    let frame_idx = self.fn_stack.len
    if frame_idx == 0 { return }
    let frame = &self.fn_stack[frame_idx - 1]
    rs.value match {
        Some(e) => {
            let v = check_expr(self, &e)
            unify_expected(self, v, frame.return_ty, E_RETURN_MISMATCH, rs.span)
        },
        None => {
            const o = self.engine.unify(Ty.Void, frame.return_ty)
            report_unify(self, &o, E_RETURN_MISMATCH, rs.span)
        },
    }
}

// Both operands of a binary operator share one type - shifts excepted,
// since a shift count need not match the value's width. Comparisons and the
// logical connectives produce `bool`; everything else produces the operand
// type.
//
// Unifying the operands is also right for the `op_add(self: T, other: T) T`
// overload shape, so user types are no worse off than before. What it
// replaces is a bare fresh var, which let `1 + "hello"` type-check clean and
// left every arithmetic node unconstrained - so lowering saw no primitive
// and emitted the default width, compiling `i32` arithmetic at 64 bits.
//
// ponytail: operator *overload resolution* (looking `op_add` up in the
// function registry) still is not done here; the operand types are
// constrained, the callee is not.
fn check_binary(self: &Checker, bin: &BinaryExpr) Ty {
    let lhs = check_expr(self, bin.lhs)
    let rhs = check_expr(self, bin.rhs)
    return bin.op match {
        Eq => compare_result(self, lhs, rhs, bin.span),
        Ne => compare_result(self, lhs, rhs, bin.span),
        Lt => compare_result(self, lhs, rhs, bin.span),
        Gt => compare_result(self, lhs, rhs, bin.span),
        Le => compare_result(self, lhs, rhs, bin.span),
        Ge => compare_result(self, lhs, rhs, bin.span),
        And => logical_result(self, lhs, rhs, bin.span),
        Or => logical_result(self, lhs, rhs, bin.span),
        // Shifts land on the arith rule too: the count unifies with the
        // shifted value's type, matching the reference's unified result
        // for Shl/Shr/UShr - and pinning a literal count.
        _ => arith_result(self, lhs, rhs, bin.span),
    }
}

fn compare_result(self: &Checker, lhs: Ty, rhs: Ty, span: SourceSpan) Ty {
    unify_either(self, lhs, rhs, span)
    return Ty.Prim(PrimitiveKind.Bool)
}

// `a op b` imposes no direction, but the coercion ladder has one: a `char`
// coerces to `u8`, not the reverse. Probe both ways before reporting, so
// `c == 'h'` with `c: u8` is accepted exactly as `'h' == c` is.
fn unify_either(self: &Checker, a: Ty, b: Ty, span: SourceSpan) {
    let probe = self.engine.try_unify(a, b)
    if probe.is_ok() {
        const o = self.engine.unify(a, b)
        report_unify(self, &o, E_TYPE_MISMATCH, span)
        return
    }
    const o = self.engine.unify(b, a)
    report_unify(self, &o, E_TYPE_MISMATCH, span)
}

fn logical_result(self: &Checker, lhs: Ty, rhs: Ty, span: SourceSpan) Ty {
    let b = Ty.Prim(PrimitiveKind.Bool)
    const o1 = self.engine.unify(lhs, b)
    report_unify(self, &o1, E_TYPE_MISMATCH, span)
    const o2 = self.engine.unify(rhs, b)
    report_unify(self, &o2, E_TYPE_MISMATCH, span)
    return b
}

// Pointer arithmetic: `p + n` and `p - n` offset a reference by an integer
// count, so the operands deliberately do NOT unify and the result is the
// pointer type. Unifying them here is what made `s.ptr + idx` - the shape
// every slice and hash routine in the stdlib uses - fail to check.
//
// ponytail: `p - q` between two references should yield an integer
// distance, not a pointer. It currently yields the pointer type. Nothing in
// the corpus does it; fix when something does.
fn arith_result(self: &Checker, lhs: Ty, rhs: Ty, span: SourceSpan) Ty {
    let lhs_is_ref = self.engine.resolve(lhs) match { Ref(_) => true, _ => false }
    if lhs_is_ref { return lhs }
    unify_either(self, lhs, rhs, span)
    return lhs
}

fn check_call(self: &Checker, call: &CallExpr) Ty {
    let pos_tys = list(call.args.len, self.allocator)
    let named_seen = false
    for i in 0..call.args.len {
        let a = &call.args[i]
        a.* match {
            Positional(e) => pos_tys.push(check_expr(self, e)),
            Named(named) => { let _r = check_expr(self, named.value); named_seen = true },
        }
    }
    // Variant constructors take no named arguments, so their presence
    // rules the variant interpretation out before any lookup.
    if !named_seen {
        let vt = variant_call(self, call, &pos_tys)
        if vt.is_some() {
            pos_tys.deinit()
            return vt.unwrap()
        }
        let ti = call.callee.* match {
            Identifier(ide) => type_instantiation_call(self, &ide, &pos_tys),
            _ => null,
        }
        if ti.is_some() {
            pos_tys.deinit()
            return ti.unwrap()
        }
        let rc = resolve_call(self, call, &pos_tys)
        if rc.is_some() {
            pos_tys.deinit()
            return rc.unwrap()
        }
    }
    pos_tys.deinit()
    // Named-argument calls keep the fresh-var fallback - see
    // docs/known-issues.md (Bootstrap Self-Host).
    let _r = check_expr(self, call.callee)
    return self.engine.fresh_var()
}

// Resolve a call to its target: registry overloads (direct, or UFCS with
// the receiver as first argument), a Func-typed struct field, or a
// Func-typed value. Some(ty) is the call's type - failures inside report
// a diagnostic and yield a fresh var so inference continues. Null means
// the callee shape has no resolution path; the caller falls back.
fn resolve_call(self: &Checker, call: &CallExpr, arg_tys: &List(Ty)) Ty? {
    return call.callee.* match {
        Identifier(ide) => resolve_direct_call(self, call, &ide, arg_tys),
        MemberAccess(ma) => resolve_method_call(self, call, &ma, arg_tys),
        _ => null,
    }
}

// `foo(args)` - registry overloads win over value bindings, mirroring
// the reference checker's call order; a value binding of function type
// is the fallback.
fn resolve_direct_call(self: &Checker, call: &CallExpr, ide: &IdentifierExpr, arg_tys: &List(Ty)) Ty? {
    let vis = fn_visibility(self)
    let cands = self.functions.lookup(ide.name, &vis) match {
        FnLookFound(c) => Some(c),
        _ => null,
    }
    if cands.is_some() {
        let candidates = cands.unwrap()
        let pick = resolve_overload(self, &candidates, arg_tys, call.span)
        candidates.deinit()
        return Some(commit_pick(self, pick, ide.name, arg_tys.len, call.span))
    }
    let callee_ty = check_expr(self, call.callee)
    return Some(indirect_call(self, callee_ty, arg_tys, call.span))
}

// `recv.method(args)` - a Func-typed struct field dispatches directly
// (the vtable pattern wins over UFCS, as in the reference checker);
// otherwise the receiver becomes the first argument of a registry
// overload, retried with the receiver adapted between value and
// reference forms.
fn resolve_method_call(self: &Checker, call: &CallExpr, ma: &MemberAccessExpr, arg_tys: &List(Ty)) Ty? {
    let recv_ty = check_expr(self, ma.receiver)

    let fc = field_call(self, &recv_ty, ma.member, arg_tys, call.span)
    if fc.is_some() { return fc }

    let vis = fn_visibility(self)
    let cands = self.functions.lookup(ma.member, &vis) match {
        FnLookFound(c) => Some(c),
        _ => null,
    }
    if cands.is_none() {
        push_diag_e(self, call.span, E_UNKNOWN_IDENT,
            $"unresolved function `{ma.member}`")
        return Some(self.engine.fresh_var())
    }
    let candidates = cands.unwrap()

    // A still-unbound receiver (a construct inference doesn't cover yet)
    // cannot arbitrate an overload set - committing the first match would
    // bind it arbitrarily. Leave the call untyped until the receiver is
    // known.
    let recv_unbound = self.engine.resolve(recv_ty) match { Var(_) => true, _ => false }
    if recv_unbound and candidates.len > 1 {
        candidates.deinit()
        return Some(self.engine.fresh_var())
    }

    let pick = receiver_overload(self, &candidates, recv_ty, arg_tys, call.span)
    if pick.is_none() {
        // Receiver adaptation: a value receiver retries the `&T` overload
        // and a reference receiver retries the value overload.
        let r = self.engine.resolve(recv_ty)
        let adapted = r match {
            Ref(inner) => inner.*,
            _ => self.engine.mk_ref(r),
        }
        pick = receiver_overload(self, &candidates, adapted, arg_tys, call.span)
    }
    if pick.is_none() {
        pick = deref_retry(self, &candidates, recv_ty, arg_tys, call.span)
    }
    candidates.deinit()
    return Some(commit_pick(self, pick, ma.member, arg_tys.len, call.span))
}

// One overload-resolution attempt with `recv` prepended as the first
// argument.
fn receiver_overload(self: &Checker, candidates: &List(FunctionScheme), recv: Ty, arg_tys: &List(Ty), span: SourceSpan) OverloadPick? {
    let full = list(arg_tys.len + 1, self.allocator)
    full.push(recv)
    full.push_all(arg_tys.as_slice())
    let pick = resolve_overload(self, candidates, &full, span)
    full.deinit()
    return pick
}

// Peel `op_deref` wrappers: a receiver whose type defines it retries the
// method against the wrapped inner value, both by reference and by value
// (mirrors the reference checker's UFCS deref chain, with the same depth
// bound). The deref chain is not yet recorded for lowering. A dead-end
// chain leaves its committed deref unifications behind - parity with the
// reference checker, which also resolves each hop non-speculatively.
fn deref_retry(self: &Checker, candidates: &List(FunctionScheme), recv_ty: Ty, arg_tys: &List(Ty), span: SourceSpan) OverloadPick? {
    let vis = fn_visibility(self)
    let dcands = self.functions.lookup("op_deref", &vis) match {
        FnLookFound(c) => Some(c),
        _ => null,
    }
    if dcands.is_none() { return null }
    let dc = dcands.unwrap()
    defer dc.deinit()

    let current = self.engine.resolve(recv_ty)
    let depth = 0usize
    loop {
        if depth >= 10 { return null }
        depth = depth + 1

        let peeled = current match {
            Ref(inner) => self.engine.resolve(inner.*),
            _ => current,
        }
        let is_nominal = peeled match { Nominal(_) => true, _ => false }
        if !is_nominal { return null }

        let dargs = list(1, self.allocator)
        dargs.push(self.engine.mk_ref(peeled))
        let dpick = resolve_overload(self, &dc, &dargs, span)
        dargs.deinit()
        if dpick.is_none() { return null }

        let dret = self.engine.resolve(dpick.unwrap().ret)
        let inner = dret match {
            Ref(i) => self.engine.resolve(i.*),
            _ => return null,
        }

        let pick = receiver_overload(self, candidates, dret, arg_tys, span)
        if pick.is_none() {
            pick = receiver_overload(self, candidates, inner, arg_tys, span)
        }
        if pick.is_some() { return pick }

        current = inner
    }
    return null
}

// A committed pick of a generic overload becomes a pending
// specialization - drained once the enclosing body's inference has
// settled (M10). `is_operator` selects which table the drain rewrites:
// `resolved_ops` for operator nodes, `resolved_targets` for calls.
fn note_pending(self: &Checker, span: SourceSpan, is_operator: bool, pick: &OverloadPick) {
    if pick.inst.is_none() { return }
    let inst = pick.inst.unwrap()
    self.pending_specs.push(PendingSpec {
        span = span,
        is_operator = is_operator,
        function_id = pick.id,
        tp_binds = inst.tp_binds,
        inst_params = inst.params,
        inst_ret = inst.ret,
        caller_module = self.current_module.unwrap(),
    })
}

// Record the winner on the call node and return its instantiated return
// type; report when no overload matched.
fn commit_pick(self: &Checker, pick: OverloadPick?, name: String, n_args: usize, span: SourceSpan) Ty {
    return pick match {
        Some(p) => {
            self.results.record_target(node_id_of(span), ResolvedTarget.RtFunction(p.id))
            note_pending(self, span, false, &p)
            p.ret
        },
        None => {
            push_diag_e(self, span, E_NO_OVERLOAD,
                $"no matching overload for `{name}` with {n_args} argument(s)")
            self.engine.fresh_var()
        },
    }
}

// `recv.field(args)` where `field` is a Func-typed struct field - the
// vtable-dispatch pattern. Null when the receiver is not a struct or has
// no Func field by that name - the UFCS path takes over.
fn field_call(self: &Checker, recv_ty: &Ty, name: String, arg_tys: &List(Ty), span: SourceSpan) Ty? {
    let fty = struct_field_lookup(self, recv_ty, name)
    if fty.is_none() { return null }
    let f = self.engine.resolve(fty.unwrap()) match {
        Func(ft) => ft,
        _ => return null,
    }
    if f.params.len != arg_tys.len {
        push_diag_e(self, span, E_NO_OVERLOAD,
            $"no matching overload for `{name}` with {arg_tys.len} argument(s)")
        return Some(self.engine.fresh_var())
    }
    for i in 0..arg_tys.len {
        const o = self.engine.unify(arg_tys[i], f.params[i])
        report_unify(self, &o, E_TYPE_MISMATCH, span)
    }
    return Some(f.ret.*)
}

// A callee that is a value: a Func-typed binding calls directly; an
// unresolved binding is constrained to a function of the call's shape
// (so lambda-typed locals infer); anything else is not callable.
fn indirect_call(self: &Checker, callee_ty: Ty, arg_tys: &List(Ty), span: SourceSpan) Ty {
    let z = self.engine.resolve(callee_ty)
    let ft = z match {
        Func(f) => Some(f),
        _ => null,
    }
    if ft.is_some() {
        let f = ft.unwrap()
        if f.params.len != arg_tys.len {
            push_diag_e(self, span, E_NO_OVERLOAD,
                $"no matching overload with {arg_tys.len} argument(s)")
            return self.engine.fresh_var()
        }
        for i in 0..arg_tys.len {
            const o = self.engine.unify(arg_tys[i], f.params[i])
            report_unify(self, &o, E_TYPE_MISMATCH, span)
        }
        return f.ret.*
    }
    if z.is_error() { return Ty.Error }
    let is_var = z match { Var(_) => true, _ => false }
    if is_var {
        let ps = list(arg_tys.len, self.allocator)
        ps.push_all(arg_tys.as_slice())
        let ret = self.engine.fresh_var()
        const o = self.engine.unify(callee_ty, self.engine.mk_func(ps, ret))
        report_unify(self, &o, E_TYPE_MISMATCH, span)
        return ret
    }
    push_diag_e(self, span, E_NO_OVERLOAD,
        $"expression of non-function type is not callable")
    return self.engine.fresh_var()
}

// The winning overload for a call site: registry id plus instantiated
// return type. For a generic winner, `inst` carries the instantiation
// the commit sites turn into a `PendingSpec` (M10); null for
// monomorphic winners.
type OverloadPick = struct {
    id: u32
    ret: Ty
    inst: PickInst?
}

// A generic winner's instantiated shape: the quantified-id → fresh-var
// mapping plus the fresh-var-bearing parameter and return types. All
// zonk to concrete types once the surrounding inference settles.
type PickInst = struct {
    tp_binds: Dict(VarId, Ty)
    params: List(Ty)
    ret: Ty
}

// Pick the best candidate for the argument types and commit its
// unification. Each candidate is probed inside an engine checkpoint that
// is rolled back, so losing candidates leave no bindings. Arity accepts
// [required, total]: trailing defaulted params may be omitted and a
// variadic tail takes any surplus. Preference: fewer quantified vars,
// then lower coercion cost, then registration order.
fn resolve_overload(self: &Checker, candidates: &List(FunctionScheme), arg_tys: &List(Ty), span: SourceSpan) OverloadPick? {
    let best: usize? = null
    let best_cost = 0u32
    let best_generics = 0usize

    for ci in 0..candidates.len {
        let c = &candidates[ci]
        let probed = probe_candidate(self, c, arg_tys)
        if probed.is_some() {
            let cost = probed.unwrap()
            let generics = c.signature.quantified.len()
            let better = best.is_none() or generics < best_generics
                or (generics == best_generics and cost < best_cost)
            if better {
                best = Some(ci)
                best_cost = cost
                best_generics = generics
            }
        }
    }
    if best.is_none() { return null }

    let w = &candidates[best.unwrap()]
    let binds: Dict(VarId, Ty) = dict(self.allocator)
    let inst_ty = self.engine.resolve(self.engine.specialize_capture(&w.signature, &binds))
    let ft = inst_ty match {
        Func(x) => Some(x),
        _ => null,
    }
    if ft.is_none() {
        binds.deinit()
        return null
    }
    let f = ft.unwrap()
    let checked = non_variadic_arg_count(w, &f, arg_tys.len)
    for i in 0..checked {
        const o = self.engine.unify(arg_tys[i], f.params[i])
        report_unify(self, &o, E_TYPE_MISMATCH, span)
    }
    let inst: PickInst? = null
    if w.signature.quantified.len() > 0 {
        inst = Some(PickInst { tp_binds = binds, params = f.params, ret = f.ret.* })
    } else {
        binds.deinit()
    }
    return Some(OverloadPick { id = w.id, ret = f.ret.*, inst = inst })
}

// Speculatively check one candidate: null when it cannot take these
// arguments, else the total coercion cost plus a penalty per omitted
// defaulted param (fuller matches win, as in the reference checker).
fn probe_candidate(self: &Checker, c: &FunctionScheme, arg_tys: &List(Ty)) u32? {
    let f = scheme_fn_ty(self, &c.signature) match {
        Some(ft) => ft,
        None => return null,
    }
    if arg_tys.len < c.required_params { return null }
    if !c.has_variadic and arg_tys.len > f.params.len { return null }

    let checked = non_variadic_arg_count(c, &f, arg_tys.len)
    self.engine.push_checkpoint()
    let ok = true
    let cost = 0u32
    let i = 0usize
    while ok and i < checked {
        self.engine.unify(arg_tys[i], f.params[i]) match {
            Unified(u) => cost = cost + u.cost,
            _ => ok = false,
        }
        i = i + 1
    }
    self.engine.rollback()
    if !ok { return null }

    let omitted = if arg_tys.len < f.params.len { f.params.len - arg_tys.len } else { 0usize }
    if c.has_variadic and omitted > 0 { omitted = omitted - 1 }
    return Some(cost + (omitted as u32) * 100u32)
}

// A candidate's signature specialized fresh and viewed as a function.
fn scheme_fn_ty(self: &Checker, s: &Scheme) FunctionTy? {
    return self.engine.resolve(self.engine.specialize(s)) match {
        Func(ft) => Some(ft),
        _ => null,
    }
}

// How many leading args unify against declared params: everything up to
// the variadic tail. Surplus variadic args are not element-checked yet -
// see docs/known-issues.md (Bootstrap Self-Host).
fn non_variadic_arg_count(c: &FunctionScheme, f: &FunctionTy, n_args: usize) usize {
    let non_variadic = if c.has_variadic { f.params.len - 1 } else { f.params.len }
    return if n_args < non_variadic { n_args } else { non_variadic }
}

// `Enum.Variant(args)` or bare `Variant(args)` - payload-carrying enum
// variant construction. Null for every other call shape; the caller
// falls through to function/indirect call handling. The callee is NOT
// checked as a value on the variant path - a type name has no value
// binding, so checking it would wrongly report `unknown identifier`.
fn variant_call(self: &Checker, call: &CallExpr, arg_tys: &List(Ty)) Ty? {
    let node = node_id_of(call.span)
    return call.callee.* match {
        MemberAccess(ma) => {
            let id = enum_receiver(self, ma.receiver)
            id match {
                Some(i) => construct_variant(self, i, ma.member, arg_tys, call.span, node),
                None => null,
            }
        },
        Identifier(ide) => unqualified_variant_call(self, &ide, arg_tys, call.span, node),
        _ => null,
    }
}

// Bare `Variant(args)`: locals and functions win over variant names, so
// the constructor interpretation only fires when the name has neither a
// value binding nor a visible function candidate.
fn unqualified_variant_call(self: &Checker, ide: &IdentifierExpr, arg_tys: &List(Ty), span: SourceSpan, node: NodeId) Ty? {
    if name_is_value_bound(self, ide.name) { return null }
    let vis = current_visibility(self)
    let nid = self.nominals.lookup_variant(ide.name, arg_tys.len, &vis)
    if nid.is_none() { return null }
    return construct_variant(self, nid.unwrap(), ide.name, arg_tys, span, node)
}

// True when the name resolves as a value - a local binding or a visible
// function. Values always win over variant and type-name interpretations.
fn name_is_value_bound(self: &Checker, name: String) bool {
    if self.env.lookup(name).is_some() { return true }
    let vis = fn_visibility(self)
    return self.functions.lookup(name, &vis) match {
        FnLookFound(_) => true,
        _ => false,
    }
}

// `Entry(K, V)` - a visible nominal called with type arguments yields the
// instantiated nominal itself; the `Type(T)` coercion lifts it where a
// reified type parameter expects it.
fn type_instantiation_call(self: &Checker, ide: &IdentifierExpr, arg_tys: &List(Ty)) Ty? {
    if name_is_value_bound(self, ide.name) { return null }
    let vis = current_visibility(self)
    let nid = self.nominals.lookup(ide.name, &vis) match {
        NomLookFound(n) => Some(n),
        _ => null,
    }
    if nid.is_none() { return null }
    let id = nid.unwrap()
    let n_params = self.nominals.get(id).* match {
        NomStruct(s) => s.type_params.len,
        NomEnum(e) => e.type_params.len,
    }
    if n_params != arg_tys.len { return null }
    let args = list(arg_tys.len, self.allocator)
    args.push_all(arg_tys.as_slice())
    return Some(Ty.Nominal(NominalRef { id = id, args = args }))
}

// Expression-context if. Without an else the value is void and the then
// branch's value is discarded; with one, the branches must agree.
fn check_if(self: &Checker, if_expr: &IfExpr) Ty {
    let _r = check_expr(self, if_expr.condition)
    let then_ty = check_block(self, &if_expr.then_branch)
    let else_ty = if_expr.else_branch match {
        NoElse => return Ty.Void,
        Block(b) => check_block(self, &b),
        If(nested) => check_if(self, nested),
    }
    return join_types(self, then_ty, else_ty, E_BRANCH_MISMATCH, if_expr.span)
}

// `S { f = v, ... }` - the literal's type is the resolved nominal `S`; each
// initializer is unified against its declared field type (so an unsuffixed
// literal resolves and a mismatch is reported). An anonymous `.{ … }` (no
// type) defers to a fresh var until record literals land.
fn check_struct_lit(self: &Checker, lit: &StructLiteralExpr) Ty {
    if lit.type_expr.is_none() {
        // The anonymous form types as a fresh var the context binds
        // (return type, annotation, call parameter). Field constraints
        // can't apply until that binding exists, so the initializers are
        // parked and `resolve_anon_literals` unifies them against the
        // nominal's field types once inference settles.
        let recs: List(AnonFieldRec) = list(lit.fields.len, self.allocator)
        for i in 0..lit.fields.len {
            let fi = &lit.fields[i]
            let v = check_field_value(self, fi)
            recs.push(AnonFieldRec { name = fi.name, ty = v, span = fi.span })
        }
        let anon_var = self.engine.fresh_var()
        self.pending_anons.push(PendingAnon { ty = anon_var, fields = recs })
        return anon_var
    }
    let ty = resolve_type_expr(self, lit.type_expr.unwrap())

    // A generic struct constructed by NAME must spell its type arguments:
    // `Pair(i64) { ... }`. Inference from fields belongs to the anonymous
    // `.{ ... }` form. Without this check the literal records an
    // under-instantiated nominal (`Pair` with no arguments), which no
    // downstream layout query can size - the reference checker rejects
    // the same shape with E2019.
    let missing = generic_struct_missing_args(self, &ty)
    if missing.is_some() {
        let n = missing.unwrap()
        const msg = $"generic struct `{n}` requires type arguments, use `{n}(...)` or `.{{ ... }}`"
        push_diag_e(self, lit.span, E_GENERIC_NEEDS_ARGS, msg)
        // Field expressions still check for their own errors; the literal
        // itself has no usable type.
        for i in 0..lit.fields.len {
            let _v = check_field_value(self, &lit.fields[i])
        }
        return Ty.Error
    }

    for i in 0..lit.fields.len {
        let fi = &lit.fields[i]
        let v = check_field_value(self, fi)
        let fty = struct_field_lookup(self, &ty, fi.name)
        if fty.is_some() {
            const o = self.engine.unify(v, fty.unwrap())
            report_unify(self, &o, E_TYPE_MISMATCH, fi.span)
        }
    }
    return ty
}

// The struct's display name when `ty` is a nominal struct instantiated
// with fewer (or more) type arguments than its declaration has parameters;
// null when the instantiation is well-formed or `ty` isn't a struct.
fn generic_struct_missing_args(self: &Checker, ty: &Ty) String? {
    let nr = ty.* match {
        Nominal(n) => n,
        _ => return null,
    }
    let sd = self.nominals.get(nr.id).* match {
        NomStruct(s) => s,
        _ => return null,
    }
    if nr.args.len == sd.type_params.len { return null }
    return Some(short_name_of(sd.fqn, last_dot(sd.fqn)))
}

// The value of a field initializer: the explicit `f = expr`, or - for
// shorthand `S { f }` - the in-scope binding named like the field.
fn check_field_value(self: &Checker, fi: &StructFieldInit) Ty {
    if fi.value.is_some() { return check_expr(self, fi.value.unwrap()) }
    let id = IdentifierExpr { span = fi.span, name = fi.name }
    return check_identifier(self, &id)
}

// `recv.member` - when the receiver is a struct with a field of that name,
// the access yields the field's (substituted) type. Otherwise it defers to
// a fresh var: member syntax also bases UFCS calls, which resolve elsewhere.
fn check_member(self: &Checker, ma: &MemberAccessExpr) Ty {
    // Qualified enum-variant access (`Ord.Less`) is resolved before the
    // receiver is checked as a value: a type name has no value binding, so
    // checking it would wrongly report `unknown identifier`.
    let ev = enum_variant_access(self, ma)
    if ev.is_some() { return ev.unwrap() }

    let recv = check_expr(self, ma.receiver)
    let fty = struct_field_lookup(self, &recv, ma.member)
    if fty.is_some() { return fty.unwrap() }
    let tp = tuple_projection(self, &recv, ma.member)
    if tp.is_some() { return tp.unwrap() }
    return self.engine.fresh_var()
}

// `t.0` / `t.1` - positional projection on a tuple-typed receiver (one
// reference peeled). Null for non-tuples, non-numeric members, and
// out-of-range indices - those fall through to UFCS resolution.
fn tuple_projection(self: &Checker, recv: &Ty, member: String) Ty? {
    let r = self.engine.resolve(recv.*)
    let peeled = r match {
        Ref(inner) => self.engine.resolve(inner.*),
        _ => r,
    }
    let elems = peeled match {
        Tuple(es) => es,
        _ => return null,
    }
    let idx = parse_decimal(member)
    if idx.is_none() { return null }
    if idx.unwrap() >= elems.len { return null }
    return Some(elems[idx.unwrap()])
}

// Qualified enum-variant access `EnumName.Variant`: a bare receiver naming an
// in-scope enum whose `member` is one of its payload-less variants yields the
// enum's nominal type. Null for every other shape, leaving field access and
// UFCS untouched. Payload-carrying variants only construct through call
// syntax - see `variant_call`.
fn enum_variant_access(self: &Checker, ma: &MemberAccessExpr) Ty? {
    let id = enum_receiver(self, ma.receiver)
    if id.is_none() { return null }
    return construct_nullary(self, id.unwrap(), ma.member, ma.span)
}

// The nominal a bare-identifier receiver names, when it is not shadowed
// by a value binding. Locals win: `x.foo` on a local `x` is field access
// or UFCS even if a type `x` is also in scope.
fn enum_receiver(self: &Checker, recv: &Expr) NominalId? {
    let name = recv.* match {
        Identifier(ide) => Some(ide.name),
        _ => null,
    }
    if name.is_none() { return null }
    if self.env.lookup(name.unwrap()).is_some() { return null }

    let vis = current_visibility(self)
    return self.nominals.lookup(name.unwrap(), &vis) match {
        NomLookFound(id) => Some(id),
        _ => null,
    }
}

fn construct_nullary(self: &Checker, id: NominalId, vname: String, span: SourceSpan) Ty? {
    let empty = list(0, self.allocator)
    let out = construct_variant(self, id, vname, &empty, span, node_id_of(span))
    empty.deinit()
    return out
}

// Construct an enum variant: fresh type args for the enum's params, the
// variant's payload types substituted against them, and each argument
// unified with its payload. Null when the nominal is not an enum, names
// no such variant, or the argument count differs - callers fall through
// to the other call forms. On success the variant target is recorded
// for lowering and go-to-definition.
fn construct_variant(self: &Checker, id: NominalId, vname: String, arg_tys: &List(Ty), span: SourceSpan, node: NodeId) Ty? {
    let ed = self.nominals.get(id).* match {
        NomEnum(e) => Some(e),
        _ => null,
    }
    if ed.is_none() { return null }
    let e = ed.unwrap()

    let vnum = 0u32
    let found = false
    for i in 0..e.variants.len {
        if !found and e.variants[i].name == vname {
            vnum = i as u32
            found = true
        }
    }
    if !found { return null }
    let payloads = &e.variants[vnum as usize].payloads
    if payloads.len != arg_tys.len { return null }

    let subst = dict(self.allocator)
    let args = list(e.type_params.len, self.allocator)
    for k in 0..e.type_params.len {
        let fresh = self.engine.fresh_var()
        subst.set(e.type_params[k], fresh)
        args.push(fresh)
    }
    for i in 0..payloads.len {
        let pty = substitute(&payloads[i], &subst, self.allocator)
        const o = self.engine.unify(arg_tys[i], pty)
        report_unify(self, &o, E_TYPE_MISMATCH, span)
    }
    subst.deinit()
    self.results.record_target(node, ResolvedTarget.RtEnumVariant(id, vnum))
    return Some(Ty.Nominal(NominalRef { id = id, args = args }))
}

// A struct field's declared type by name, substituted against the
// receiver instance's type arguments - a read must never bind the
// definition's shared type-param vars. Null when the (zonked,
// one-reference-peeled) type is not a struct or has no such field.
fn struct_field_lookup(self: &Checker, recv: &Ty, name: String) Ty? {
    let z = self.engine.zonk(recv.*)
    let peeled = z match {
        Ref(inner) => inner.*,
        _ => z,
    }
    let nr_opt = peeled match {
        Nominal(n) => Some(n),
        _ => null,
    }
    if nr_opt.is_none() { return null }
    let nr = nr_opt.unwrap()
    let def_node = self.nominals.get(nr.id)
    let sd_opt = def_node.* match {
        NomStruct(s) => Some(s),
        _ => null,
    }
    if sd_opt.is_none() { return null }
    let sd = sd_opt.unwrap()
    for i in 0..sd.fields.len {
        if sd.fields[i].name == name {
            if sd.type_params.len == 0 or sd.type_params.len != nr.args.len {
                return Some(sd.fields[i].ty)
            }
            let subst = dict(self.allocator)
            for k in 0..sd.type_params.len { subst.set(sd.type_params[k], nr.args[k]) }
            let out = substitute(&sd.fields[i].ty, &subst, self.allocator)
            subst.deinit()
            return Some(out)
        }
    }
    return null
}

// ─────────────────────────────────────────────────────────────────────
// Top-level driver
// ─────────────────────────────────────────────────────────────────────

pub fn check_all(self: &Checker, modules: &List(Module), paths: &List(String)) TypeCheckResult {
    // Wire the import graph before any name resolution runs.
    build_visibility(self, modules, paths)

    // Phase 1: every module's type names are registered before any body
    // resolves, so a struct field or enum payload can name a type from
    // another module regardless of the order modules are checked in.
    for i in 0..modules.len {
        collect_nominal_names(self, &modules[i], paths[i])
    }
    for i in 0..modules.len {
        resolve_nominal_bodies(self, &modules[i], paths[i])
    }
    // Phase 2: signatures.
    for i in 0..modules.len {
        collect_signatures(self, &modules[i], paths[i])
    }
    // Phase 3: bodies.
    for i in 0..modules.len {
        check_module_bodies(self, &modules[i], paths[i])
    }
    // Phase 3.5: settle anonymous literals (their field pins can be
    // what makes a generic pick concrete), then instantiate every
    // generic pick the body pass recorded, transitively - a
    // specialization's body enqueues its own picks.
    resolve_anon_literals(self)
    drain_pending_specs(self)
    // Phase 3.6: any unsuffixed literal nothing ever pinned is E2001.
    validate_literals(self)

    // Zonk every node-type entry so the result is final.
    let zonked: Dict(NodeId, Ty) = dict(self.allocator)
    for entry in self.results.node_types {
        zonked.set(entry.key, self.engine.zonk(entry.value))
    }

    // Move the registries and result tables into the snapshot, then
    // replace each moved-from field with a fresh empty container so the
    // caller's later `checker.deinit()` doesn't double-free them.
    let out_resolved_ops = self.results.resolved_ops
    let out_resolved_targets = self.results.resolved_targets
    let out_instantiated_types = self.results.instantiated_types
    let out_specializations = self.specs.specs
    let out_desugars = self.results.desugars
    let out_synth_strings = self.results.synth_strings
    let out_nominals = self.nominals
    let out_functions = self.functions

    self.results.reset_side_tables()
    self.nominals = nominal_registry(self.allocator)
    self.functions = function_registry(self.allocator)
    // The moved-out spec list gets a fresh registry; the old `by_key`
    // dict is abandoned to the allocator like the other snapshots.
    self.specs = specialization_registry(self.allocator)

    return TypeCheckResult {
        node_types = zonked,
        resolved_ops = out_resolved_ops,
        resolved_targets = out_resolved_targets,
        instantiated_types = out_instantiated_types,
        specializations = out_specializations,
        desugars = out_desugars,
        synth_strings = out_synth_strings,
        nominals = out_nominals,
        functions = out_functions,
    }
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

fn parse_src(src: String, fid: i32) Module {
    let lx = lexer(src)
    let tokens = lx.tokenize()
    let p = parser(tokens)
    let cst = p.parse_module()
    let m = project_module(cst, fid)
    p.deinit()
    tokens.deinit()
    return m
}

// Parse each source as its own module, run check_all over them, and count
// error diagnostics.
fn count_check_errors(srcs: String[], paths: String[]) usize {
    let mods = list(srcs.len)
    for i in 0..srcs.len {
        mods.push(parse_src(srcs[i], i as i32))
    }
    let ps = list(paths.len)
    ps.push_all(paths)

    let chk = checker()
    let _res = check_all(&chk, &mods, &ps)
    let errors = 0usize
    for i in 0..chk.diagnostics.len {
        if chk.diagnostics[i].severity == Severity.Error { errors = errors + 1 }
    }

    chk.deinit()
    for i in 0..mods.len {
        let m = &mods[i]
        m.deinit()
    }
    mods.deinit()
    ps.deinit()
    return errors
}

test "non-generic type alias resolves cross-module" {
    // `alias_a` declares `type VarId = u32`; `alias_b` imports it and uses
    // the alias in a signature. Before the alias registry, `VarId` surfaced
    // as E2003 unknown type, so a clean run (zero errors) is the regression.
    let errors = count_check_errors(
        ["pub type VarId = u32\n", "import alias_a\nfn f(x: VarId) u32 { return x }\n"],
        ["alias_a", "alias_b"])
    assert_true(errors == 0, "cross-module alias program type-checks with no errors")
}

test "payload variant construction type-checks" {
    // Qualified single- and multi-payload construction on a non-generic
    // enum. Before this fix the callee's receiver checked as a value and
    // surfaced E2004 unknown identifier.
    let errors = count_check_errors(
        ["pub type Shape = enum { Dot\nCircle(i32)\nRect(i32, i32) }\nfn f() Shape { return Shape.Circle(3) }\nfn g() Shape { return Shape.Rect(1, 2) }\n"],
        ["shapes"])
    assert_true(errors == 0, "payload variant construction type-checks with no errors")
}

test "generic and unqualified variant construction type-checks" {
    // Generic enum: qualified `Opt.S(3)`, unqualified `S(3)`, and bare
    // payload-less `N` in expression position - each instantiates the
    // enum's type param fresh and unifies it via the declared return.
    let errors = count_check_errors(
        ["pub type Opt = enum(T) { N\nS(T) }\nfn f() Opt(i32) { return Opt.S(3) }\nfn g() Opt(i32) { return S(3) }\nfn h() Opt(i32) { return N }\n"],
        ["opts"])
    assert_true(errors == 0, "generic and unqualified variant construction type-checks with no errors")
}

test "variant payload type mismatch is reported" {
    // A float payload against an i32 variant - no coercion path exists
    // (bool would widen: bool coerces to any integer by design; a string
    // literal resolves to Error poison in these stdlib-less tests).
    let errors = count_check_errors(
        ["pub type Shape = enum { Circle(i32) }\nfn f(x: f64) Shape { return Shape.Circle(x) }\n"],
        ["shapes"])
    assert_true(errors > 0, "f64 payload against i32 variant reports a type error")
}

test "module-level constants resolve cross-module" {
    // An imported `pub const` and a same-module unannotated const both
    // resolve as identifiers; before the constant registry each surfaced
    // E2004 unknown identifier.
    let errors = count_check_errors(
        ["pub const LIMIT: u32 = 8\n", "import consts_a\nconst LOCAL = 3\nfn f() u32 { return LIMIT }\nfn g() u32 { return LOCAL }\n"],
        ["consts_a", "consts_b"])
    assert_true(errors == 0, "constant reads type-check with no errors")
}

test "qualified payload-less enum variant access type-checks" {
    // `Ord.Less` is a MemberAccess on a type-name receiver. Before this fix
    // the receiver checked as a value and surfaced E2004 unknown identifier;
    // a clean run (zero errors) returning the enum type is the regression.
    let errors = count_check_errors(
        ["pub type Ord = enum { Less = -1\nEqual = 0\nGreater = 1 }\nfn f() Ord { return Ord.Less }\n"],
        ["cmp"])
    assert_true(errors == 0, "qualified enum variant access type-checks with no errors")
}

test "direct call unifies args and returns the instantiated type" {
    let errors = count_check_errors(
        ["fn add(a: i32, b: i32) i32 { return a }\nfn f() i32 { return add(1, 2) }\n"],
        ["calls_direct"])
    assert_true(errors == 0, "direct call type-checks with no errors")
}

test "overloads pick the arity-matching candidate" {
    let errors = count_check_errors(
        ["fn pick(a: i32) i32 { return a }\nfn pick(a: i32, b: i32) i32 { return b }\nfn f() i32 { return pick(1) }\nfn g() i32 { return pick(1, 2) }\n"],
        ["calls_arity"])
    assert_true(errors == 0, "arity overload resolution type-checks with no errors")
}

test "trailing default params may be omitted at the call site" {
    let errors = count_check_errors(
        ["fn scaled(a: i32, k: i32 = 2) i32 { return a }\nfn f() i32 { return scaled(3) }\nfn g() i32 { return scaled(3, 4) }\n"],
        ["calls_defaults"])
    assert_true(errors == 0, "defaulted-param calls type-check with no errors")
}

test "ufcs receiver becomes the first argument, adapted between value and ref" {
    let errors = count_check_errors(
        ["pub type Pt = struct { x: i32 }\nfn shift(p: &Pt, d: i32) i32 { return d }\nfn f(p: &Pt) i32 { return p.shift(2) }\nfn g(p: Pt) i32 { return p.shift(2) }\n"],
        ["calls_ufcs"])
    assert_true(errors == 0, "ufcs calls type-check with no errors")
}

test "func-typed struct field dispatches as an indirect call" {
    let errors = count_check_errors(
        ["pub type Ops = struct { scale: fn(i32) i32 }\nfn f(o: &Ops) i32 { return o.scale(3) }\n"],
        ["calls_field"])
    assert_true(errors == 0, "field call type-checks with no errors")
}

test "func-typed param called by name is an indirect call" {
    let errors = count_check_errors(
        ["fn apply(op: fn(i32) i32, x: i32) i32 { return op(x) }\n"],
        ["calls_indirect"])
    assert_true(errors == 0, "indirect call through a param type-checks with no errors")
}

test "wrong argument type in a call is reported" {
    // f64 against i32 has no coercion path (bool would widen by design;
    // string literals are Error poison in these stdlib-less tests).
    let errors = count_check_errors(
        ["fn takes(a: i32) i32 { return a }\nfn f(x: f64) i32 { return takes(x) }\n"],
        ["calls_mismatch"])
    assert_true(errors > 0, "f64 argument against i32 param reports an error")
}

test "a ref-form index operator types as its pointee" {
    let errors = count_check_errors(
        ["type Box = struct { v: i32 }\nfn op_index_ref(b: &Box, i: usize) &i32 { return &b.v }\nfn f(b: &Box) i32 { return b[0usize] }\n"],
        ["ix_ref"])
    assert_true(errors == 0, "`&T` return means the index yields `T`")
}

test "a value-form index operator types as its return" {
    let errors = count_check_errors(
        ["type Box = struct { v: i32 }\nfn op_index(b: &Box, i: usize) i32 { return b.v }\nfn f(b: &Box) i32 { return b[0usize] }\n"],
        ["ix_val"])
    assert_true(errors == 0, "the operator's return type is the index's type")
}

test "indexing a type with no operator is reported" {
    let errors = count_check_errors(
        ["type Box = struct { v: i32 }\nfn f(b: &Box) i32 { return b[0usize] }\n"],
        ["ix_none"])
    assert_true(errors == 1, "a non-indexable base is E2028, not a silent fresh var")
}

test "a generic struct literal named without type arguments is E2019" {
    let errors = count_check_errors(
        ["type Pair = struct(T) { a: T, b: T }\nfn f() i64 { let p = Pair { a = 1i64, b = 2i64 } return p.a }\n"],
        ["underinst"])
    assert_true(errors >= 1, "a named generic literal must spell its arguments (or use `.{ ... }`)")
}

test "a generic struct literal with explicit arguments checks clean" {
    let errors = count_check_errors(
        ["type Pair = struct(T) { a: T, b: T }\nfn f() i64 { let p = Pair(i64) { a = 1, b = 2 } return p.a }\n"],
        ["inst"])
    assert_true(errors == 0, "explicit arguments instantiate the literal")
}

test "a bool index is rejected before any operator lookup" {
    let errors = count_check_errors(
        ["type Box = struct { v: i32 }\nfn op_index(b: &Box, i: bool) i32 { return b.v }\nfn f(b: &Box) i32 { return b[true] }\n"],
        ["ix_bool"])
    assert_true(errors == 1, "`bool` never indexes, even where an overload would take it")
}

// There is no implicit `T -> Option(T)` wrap: a value arm joining a
// `null` arm must say `Some(v)` explicitly, in either arm order. A real
// `core.option` module is part of each test program — without it the
// registry has no Option, `null` types as `Ty.Error`, and every outcome
// passes vacuously.
const OPTION_SRC: String = "pub type Option = enum(T) {\n    None,\n    Some(T),\n}\n"

test "match arms join a Some arm and a null arm into an optional" {
    let errors = count_check_errors(
        [OPTION_SRC, "import core.option\ntype E = enum { A(i32) B }\nfn f(e: &E) i32? { return e.* match { A(v) => Some(v), B => null } }\nfn g(e: &E) i32? { return e.* match { B => null, A(v) => Some(v) } }\n"],
        ["core.option", "arm_join"])
    assert_true(errors == 0, "explicit Some joins with null in either arm order")
}

test "a bare value arm does not implicitly wrap into an optional" {
    let errors = count_check_errors(
        [OPTION_SRC, "import core.option\ntype E = enum { A(i32) B }\nfn f(e: &E) i32? { return e.* match { A(v) => v, B => null } }\n"],
        ["core.option", "arm_bare"])
    assert_true(errors > 0, "`T` never becomes `Option(T)` without `Some`")
}

test "if/else branches join the same way match arms do" {
    let errors = count_check_errors(
        [OPTION_SRC, "import core.option\nfn f(c: bool, v: i32) i32? { if c { return Some(v) } else { return null } }\nfn g(c: bool, v: i32) i32? { return if c { Some(v) } else { null } }\n"],
        ["core.option", "branch_join"])
    assert_true(errors == 0, "a `Some` branch and a `null` branch settle on `Option(T)`")
}

test "a bare value branch does not implicitly wrap into an optional" {
    let errors = count_check_errors(
        [OPTION_SRC, "import core.option\nfn f(c: bool, v: i32) i32? { if c { return v } else { return null } }\n"],
        ["core.option", "branch_bare"])
    assert_true(errors > 0, "return of bare `T` against `T?` is an error")
}

test "unary operators type from their operand, not a fresh var" {
    // `-x` on f64 must record f64 - the fresh-var fallback made lowering
    // emit integer negation over a double (docs/known-issues.md). The
    // wrong-result-type variants prove the node carries the operand's
    // type rather than an unconstrained var that unifies with anything.
    let errors = count_check_errors(
        ["fn f(x: f64) f64 { return -x }\nfn g(x: u32) u32 { return ~x }\nfn h(b: bool) bool { return !b }\n"],
        ["unary_ok"])
    assert_true(errors == 0, "neg/bitnot/not over matching operand types check clean")

    let neg_errors = count_check_errors(
        ["fn f(x: f64) i32 { return -x }\n"],
        ["unary_neg_ty"])
    assert_true(neg_errors > 0, "`-f64` returned as i32 is a mismatch, not a silent fresh var")
}

test "logical not requires a bool operand" {
    let errors = count_check_errors(
        ["fn f(x: i32) bool { return !x }\n"],
        ["unary_not_i32"])
    assert_true(errors > 0, "`!` over i32 is rejected")
}

// M8: `??` and `?`.

test "coalesce unwraps or chains by the right operand's shape" {
    let errors = count_check_errors(
        [OPTION_SRC, "import core.option\nfn f(o: i32?, d: i32) i32 { return o ?? d }\nfn g(a: i32?, b: i32?) i32? { return a ?? b }\n"],
        ["core.option", "coalesce_ok"])
    assert_true(errors == 0, "Option(T) ?? T and Option(T) ?? Option(T) both check clean")
}

test "coalesce rejects a mismatched fallback and a non-Option left side" {
    let mismatch = count_check_errors(
        [OPTION_SRC, "import core.option\nfn f(o: i32?, d: f64) i32 { return o ?? d }\n"],
        ["core.option", "coalesce_bad_rhs"])
    assert_true(mismatch > 0, "f64 fallback against Option(i32) is a mismatch")

    let bare = count_check_errors(
        [OPTION_SRC, "import core.option\nfn g(x: i32) i32 { return x ?? 0 }\n"],
        ["core.option", "coalesce_bad_lhs"])
    assert_true(bare > 0, "`??` over a non-Option left side is rejected")
}

// The `?` fixtures register the real well-known modules: `core.try` for
// `TryResult` and `core.option` for `Option` plus its `op_try`, copied
// from the stdlib.
const TRY_SRC: String = "pub type TryResult = enum(T, R) {\n    Continue(T),\n    Return(R),\n}\n"
const OPTION_TRY_SRC: String = "import core.try\npub type Option = enum(T) {\n    None,\n    Some(T),\n}\npub fn op_try(self: Option($T)) TryResult(T, Option($U)) {\n    return self match {\n        Some(v) => TryResult.Continue(v),\n        None => TryResult.Return(None),\n    }\n}\n"

test "postfix ? types as the Continue payload and constrains the return" {
    let errors = count_check_errors(
        [TRY_SRC, OPTION_TRY_SRC, "import core.option\nfn f(o: i32?) i32? { let v = o? return Some(v + 1) }\n"],
        ["core.try", "core.option", "try_ok"])
    assert_true(errors == 0, "`o?` continues with i32 inside a fn returning i32?")
}

test "postfix ? in a function with an incompatible return is rejected" {
    let errors = count_check_errors(
        [TRY_SRC, OPTION_TRY_SRC, "import core.option\nfn f(o: i32?) i32 { let v = o? return v }\n"],
        ["core.try", "core.option", "try_bad_ret"])
    assert_true(errors > 0, "the early-returned Option cannot fit a bare i32 return")
}

test "postfix ? without an op_try overload is E2092" {
    let errors = count_check_errors(
        [TRY_SRC, OPTION_TRY_SRC, "import core.option\ntype Plain = struct { v: i32 }\nfn f(p: Plain) i32 { let v = p? return v }\n"],
        ["core.try", "core.option", "try_none"])
    assert_true(errors > 0, "`?` on a type with no op_try is rejected")
}

// M9: interpolation desugars to StringBuilder calls (RFC-004).

// Minimal StringBuilder surface the desugar resolves against. `Owned`
// stands in for OwnedString - the desugar hardcodes no type, it takes
// whatever `to_string` returns.
const INTERP_SB_SRC: String = "import core.string\nimport core.option\npub type StringBuilder = struct { n: usize }\npub type Owned = struct { n: usize }\npub fn string_builder(capacity: usize, allocator: &StringBuilder? = null) StringBuilder { return StringBuilder { n = capacity } }\npub fn append(sb: &StringBuilder, text: String) { sb.n = sb.n + text.len }\npub fn append(sb: &StringBuilder, v: i32) { sb.n = sb.n + 1 }\npub fn append(sb: &StringBuilder, v: i32, spec: String) { sb.n = sb.n + spec.len }\npub fn to_string(sb: &StringBuilder) Owned { return Owned { n = sb.n } }\npub fn deinit(sb: &StringBuilder) {}\npub fn deinit(s: &Owned) {}\n"
const INTERP_STRING_SRC: String = "pub type String = struct { ptr: &u8, len: usize }\n"

test "interpolation desugars: appends resolve and the result is to_string's type" {
    let errors = count_check_errors(
        [OPTION_SRC, INTERP_STRING_SRC, INTERP_SB_SRC, "import std.string_builder\nfn f(x: i32) i32 { const s = $\"got {x} ok\" s.deinit() return x }\n"],
        ["core.option", "core.string", "std.string_builder", "interp_ok"])
    assert_true(errors == 0, "segment and hole appends resolve; the result takes Owned's UFCS surface")

    let hole_errors = count_check_errors(
        [OPTION_SRC, INTERP_STRING_SRC, INTERP_SB_SRC, "import std.string_builder\nfn f() i32 { const s = $\"got {no_such_name}\" return 0 }\n"],
        ["core.option", "core.string", "std.string_builder", "interp_bad_hole"])
    assert_true(hole_errors > 0, "an unknown identifier inside a hole is reported")
}

test "into-builder interpolation appends onto the target and is void" {
    let errors = count_check_errors(
        [OPTION_SRC, INTERP_STRING_SRC, INTERP_SB_SRC, "import std.string_builder\nfn g(sb: &StringBuilder, x: i32) { $sb\"v={x}\" }\n"],
        ["core.option", "core.string", "std.string_builder", "interp_into"])
    assert_true(errors == 0, "the target's append overloads resolve; the statement is void")
}

test "a hole's format spec routes to the spec-taking append overload" {
    let errors = count_check_errors(
        [OPTION_SRC, INTERP_STRING_SRC, INTERP_SB_SRC, "import std.string_builder\nfn f(x: i32) i32 { const s = $\"n={x:04}\" s.deinit() return x }\n"],
        ["core.option", "core.string", "std.string_builder", "interp_spec"])
    assert_true(errors == 0, "append(sb, v, spec) resolves for `{x:04}`")
}

// ── M10 - specialization ─────────────────────────────────────────────

// Check `srcs` and hand back the full result so tests can inspect the
// specialization list. Leaks like the driver does - one-shot.
fn check_result_of(srcs: String[], paths: String[]) TypeCheckResult {
    let mods = list(srcs.len)
    for i in 0..srcs.len {
        mods.push(parse_src(srcs[i], i as i32))
    }
    let ps = list(paths.len)
    ps.push_all(paths)
    let chk = checker()
    return check_all(&chk, &mods, &ps)
}

test "a generic call instantiates once per concrete signature" {
    let res = check_result_of(
        ["pub fn id(x: $T) T { return x }\nfn main() i32 { let a = id(1) let b = id(2) let c = id(true) if c { return a } return b }\n"],
        ["m"])
    // Two i32 calls share one specialization; the bool call adds one.
    assert_eq(res.specializations.len, 2 as usize, "two concrete signatures, two specializations")
    let s0 = &res.specializations[0]
    assert_eq(s0.concrete_params.len, 1 as usize, "id takes one param")
    assert_true(s0.name == "id", "specialization names the template")
    // The instantiated bodies were re-checked: their overlays carry
    // node types for the template body's nodes.
    assert_true(s0.overlay.node_types.length > 0, "overlay recorded body node types")
}

test "generic template bodies only report when instantiated" {
    // `bad`'s body calls a function that does not exist - uninstantiated
    // the template is never validated, instantiated it reports.
    let silent = count_check_errors(
        ["pub fn bad(x: $T) T { return no_such_fn(x) }\n"],
        ["m"])
    assert_true(silent == 0, "an uninstantiated template is never validated")

    let loud = count_check_errors(
        ["pub fn bad(x: $T) T { return no_such_fn(x) }\nfn main() i32 { return bad(1) }\n"],
        ["m"])
    assert_true(loud > 0, "instantiating the template surfaces its body errors")
}

test "a nested generic call specializes transitively" {
    let res = check_result_of(
        ["pub fn inner(x: $T) T { return x }\npub fn outer(x: $T) T { return inner(x) }\nfn main() i32 { return outer(7) }\n"],
        ["m"])
    // outer(i32) instantiates, and its body's inner(x) pick drains into
    // inner(i32).
    assert_eq(res.specializations.len, 2 as usize, "outer and inner both specialize")
}

test "a self-recursive generic reuses its own specialization" {
    let res = check_result_of(
        ["pub fn rec(x: $T, n: i32) T { if n > 0 { return rec(x, n - 1) } return x }\nfn main() i32 { return rec(3, 2) }\n"],
        ["m"])
    assert_eq(res.specializations.len, 1 as usize, "recursion hits the registered key, no second entry")
}
test "a generic member call inside a partially-fixed generic instantiates" {
    // Regression: `set2(self: &D(Key, $V), ...)` is generic only through
    // a NESTED type argument. A broken `declares_generic` walked this as
    // concrete, phase 3 checked the template with V unbound, and the
    // stray pick could never infer `cap`'s type arguments.
    let errors = count_check_errors(
        ["type Key = struct { n: usize }\ntype D = struct(K, V) { n: usize\n    k: K\n    v: V\n}\nfn cap(self: &D($K, $V)) usize { return self.n }\nfn set2(self: &D(Key, $V), value: V) usize { return self.cap() }\nfn main() i32 {\n    let d: D(Key, i32) = D(Key, i32) { n = 0usize, k = Key { n = 1usize }, v = 3i32 }\n    const c = d.set2(5i32)\n    return 0\n}\n"],
        ["m"])
    assert_true(errors == 0, "cap's K and V pin from set2's concrete receiver")
}

