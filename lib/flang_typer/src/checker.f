// Checker driver — wires the engine, registries, env, and results
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
//   - `check_all(modules, &diags) TypeCheckResult` — runs the three
//     phases and zonks the engine into an immutable result. The
//     engine is dropped before this returns.
//
// Expression / statement / declaration handling is split across
// `checker_expr.f`, `checker_stmt.f`, `checker_decl.f`, and
// `checker_pattern.f` so the dispatchers stay small. Module-level
// state (engine, env, ctx) is bundled into a `Checker` struct passed
// by reference to every sub-routine — no global state.

import std.allocator
import std.dict
import std.list
import std.option
import std.set
import std.string
import std.string_builder
import flang_core.diagnostic
import flang_core.span
import flang_parser.ast
import flang_typer.type
import flang_typer.well_known
import flang_typer.scheme
import flang_typer.env
import flang_typer.inference_engine
import flang_typer.inference_results
import flang_typer.nominal_registry
import flang_typer.function_registry
import flang_typer.specialization
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

pub type Checker = struct {
    engine: Engine
    env: TypeEnv
    nominals: NominalRegistry
    functions: FunctionRegistry
    specs: SpecializationRegistry
    results: InferenceResults
    diagnostics: List(Diagnostic)

    // Working state — reset between modules.
    current_module: String?
    fn_stack: List(FnFrame)

    // Module FQN -> the set of module FQNs whose `pub` declarations are
    // visible from it. Built once per `check_all` from the modules'
    // imports: direct imports plus the transitive `pub import` closure,
    // plus the auto-imported core prelude.
    visible_by_module: Dict(OwnedString, Set(String))

    allocator: &Allocator
}

pub fn checker(allocator: &Allocator? = null) Checker {
    let alloc = allocator.or_global()
    return .{
        engine = engine(alloc),
        env = type_env(alloc),
        nominals = nominal_registry(alloc),
        functions = function_registry(alloc),
        specs = specialization_registry(alloc),
        results = inference_results(alloc),
        diagnostics = list(0, alloc),
        current_module = null,
        fn_stack = list(0, alloc),
        visible_by_module = dict(alloc),
        allocator = alloc,
    }
}

pub fn deinit(self: &Checker) {
    self.engine.deinit()
    self.env.deinit()
    self.nominals.deinit()
    self.functions.deinit()
    self.specs.deinit()
    self.results.deinit()
    self.diagnostics.deinit()
    self.fn_stack.deinit()
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
// Type aliases would resolve transparently here — for the first slice
// we don't carry an alias registry, so a `Named` reference falls
// through to a nominal / primitive lookup.
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

    let hidden_info: NomHiddenInfo? = look match {
        NomLookHidden(info) => Some(info),
        _ => null,
    }
    if hidden_info.is_some() {
        let info = hidden_info.unwrap()
        push_diag_e(self, n.span, E_UNKNOWN_TYPE,
            $"type `{n.name}` exists in module `{info.module}` but is not imported here")
        return Ty.Error
    }

    // Type-parameter in scope (from a generic-aware lookup)?
    let bound = self.env.lookup(n.name)
    if bound.is_some() { return self.engine.specialize(&bound.unwrap().scheme) }

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
    // a `0`-sized array — the parser would already have surfaced the
    // expression-evaluation error.
    let length = array_length_of(a.length)
    return self.engine.mk_array(elem, length)
}

fn array_length_of(e: &Expr) usize {
    // Array-length expressions are arbitrary integer-valued exprs —
    // parsing `text` here would re-implement integer parsing. For the
    // first slice we report the array as 0-length when the AST carries
    // anything other than a trivially-zero value; later slices will
    // route this through `const_eval`.
    return 0usize
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
    // references look it up from the env.
    let existing = self.env.lookup(g.name)
    if existing.is_some() { return self.engine.specialize(&existing.unwrap().scheme) }
    let fresh = self.engine.fresh_var()
    self.env.bind(g.name, Binding {
        scheme = mono(fresh, self.allocator),
        decl = node_id_of(g.span),
        is_const = true,
    })
    return fresh
}

// ─────────────────────────────────────────────────────────────────────
// Diagnostic helpers — small, lift to reporter when complexity grows.
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
        Some(m) => {
            let fresh: Set(String) = set(self.allocator)
            let got = self.visible_by_module.get(m)
            got match {
                Some(src) => copy_set_into(&fresh, &src),
                None => fresh.add(m),
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

    for i in 0..n {
        imports[i].deinit()
        reexports[i].deinit()
    }
    imports.deinit()
    reexports.deinit()
}

// Record module `m`'s imports as views into `paths`. An import whose
// dotted path names no loaded module is silently dropped here; the
// unresolved-import diagnostic is the loader's job.
fn collect_edges(m: &Module, paths: &List(String), imps: &List(String), reexps: &List(String), alloc: &Allocator) {
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
fn compute_visible(idx: usize, paths: &List(String), imports: &List(List(String)), reexports: &List(List(String)), out: &Set(String), alloc: &Allocator) {
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

fn dot_join(segs: &List(String), alloc: &Allocator) OwnedString {
    let sb = string_builder(0, alloc)
    for i in 0..segs.len {
        if i > 0 { sb.append('.') }
        sb.append(segs[i])
    }
    let out = sb.to_string()
    sb.deinit()
    return out
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
// Phase 1 — collect nominal types
//
// First pass: register every struct/enum/alias by FQN with a
// placeholder definition (empty fields/variants). Second pass: resolve
// each declaration's fields/variants now that every name in the module
// is known.
// ─────────────────────────────────────────────────────────────────────

// Register one module's type *names* (struct/enum placeholders). Bodies are
// resolved in a separate pass — see `resolve_nominal_bodies` — so a field or
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
            if self.nominals.contains(fqn_owned.as_view()) {
                push_diag_e(self, td.span, E_DUP_TYPE_DECL,
                    $"duplicate type declaration `{td.name}`")
                fqn_owned.deinit()
                return
            }
            // Decide nominal vs alias by inspecting the body. The
            // OwnedString is consumed by the registry on the struct/enum
            // branches; the alias branch has no use for it yet so it
            // gets freed here.
            let kind = nominal_kind_of(td.body)
            kind match {
                NkStruct => register_struct_placeholder(self, &td, fqn_owned),
                NkEnum => register_enum_placeholder(self, &td, fqn_owned),
                NkAlias => fqn_owned.deinit(),
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
    // `fqn` field is a placeholder — `register` overwrites it with the
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
// Phase 2 — collect function signatures
//
// Every `pub fn` and `fn` is registered with its polymorphic scheme
// before any body is checked. Forward references between functions in
// the same module just work; cross-module references depend on import
// visibility (out of scope for the first slice — visibility is
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
        _ => {},
    }
}

fn register_function_sig(self: &Checker, fd: &FunctionDecl) {
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

    let scheme_obj = FunctionScheme {
        name = fd.name,
        signature = scheme,
        module = self.current_module,
        is_pub = fd.is_pub,
        is_foreign = is_foreign_directive(&fd.directives),
        decl_span = fd.span,
        deprecation = null,
        id = 0u32,           // filled in by registry.register
    }
    let _r =self.functions.register(scheme_obj)
}

fn is_foreign_directive(ds: &List(DeclAttribute)) bool {
    for i in 0..ds.len {
        let d = &ds[i]
        let f = d.* match { Foreign => true, _ => false }
        if f { return true }
    }
    return false
}

// ─────────────────────────────────────────────────────────────────────
// Phase 3 — check function bodies
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
        Function(fd) => check_function_body(self, &fd),
        _ => {},
    }
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
    // skipped to avoid a spurious "expected T, got void".
    body_ty match {
        Void => {},
        _ => {
            const o = self.engine.unify(body_ty, ret)
            report_unify(self, &o, E_RETURN_MISMATCH, fd.span)
        },
    }

    let _r =self.fn_stack.pop()
    self.engine.exit_level()
    self.env.pop_scope()
}

// ─────────────────────────────────────────────────────────────────────
// Expression / statement inference — minimal subset.
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
        _ => self.engine.fresh_var(),
    }
}

fn check_literal(self: &Checker, lit: &LiteralExpr) Ty {
    return lit.value match {
        Int(_) => self.engine.fresh_var(),       // unsuffixed — context resolves
        Float(_) => self.engine.fresh_var(),
        Bool(_) => Ty.Prim(PrimitiveKind.Bool),
        String(_) => string_type(self),
        Char(_) => Ty.Prim(PrimitiveKind.Char),
        Byte(_) => Ty.Prim(PrimitiveKind.U8),
        Null => option_of_fresh(self),
    }
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
    let vis = current_visibility(self)
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
        // Multiple overloads as a value — needs context to pick.
        return self.engine.fresh_var()
    }

    push_diag_e(self, id.span, E_UNKNOWN_IDENT,
        $"unknown identifier `{id.name}`")
    return Ty.Error
}

fn check_block(self: &Checker, blk: &BlockExpr) Ty {
    self.env.push_scope()
    for i in 0..blk.stmts.len {
        let stmt = &blk.stmts[i]
        check_stmt(self, stmt)
    }
    let final_ty = blk.trailing match {
        Some(e) => check_expr(self, e),
        None => Ty.Void,
    }
    self.env.pop_scope()
    return final_ty
}

fn check_stmt(self: &Checker, stmt: &Stmt) {
    stmt.* match {
        Let(ls) => check_let(self, &ls),
        Expression(es) => { let _r = check_expr(self, &es.expr) },
        Return(rs) => check_return(self, &rs),
        _ => {},
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
                Some(i) => { const o = self.engine.unify(i, a); report_unify(self, &o, E_TYPE_MISMATCH, ls.span); a },
                None => a,
            }
        },
        None => inferred match {
            Some(i) => i,
            None => self.engine.fresh_var(),
        },
    }
    self.env.bind(ls.name, Binding {
        scheme = mono(bound_ty, self.allocator),
        decl = node_id_of(ls.span),
        is_const = ls.is_const,
    })
}

fn check_return(self: &Checker, rs: &ReturnStmt) {
    let frame_idx = self.fn_stack.len
    if frame_idx == 0 { return }
    let frame = &self.fn_stack[frame_idx - 1]
    rs.value match {
        Some(e) => {
            let v = check_expr(self, &e)
            const o = self.engine.unify(v, frame.return_ty)
            report_unify(self, &o, E_RETURN_MISMATCH, rs.span)
        },
        None => {
            const o = self.engine.unify(Ty.Void, frame.return_ty)
            report_unify(self, &o, E_RETURN_MISMATCH, rs.span)
        },
    }
}

fn check_binary(self: &Checker, bin: &BinaryExpr) Ty {
    let _r = check_expr(self, bin.lhs)
    let _r = check_expr(self, bin.rhs)
    // First slice: defer to a fresh var; real op-overload resolution
    // and primitive instruction emission lands in `checker_expr.f`
    // alongside the operator-name → function-registry lookup.
    return self.engine.fresh_var()
}

fn check_call(self: &Checker, call: &CallExpr) Ty {
    for i in 0..call.args.len {
        let a = &call.args[i]
        check_call_arg(self, a)
    }
    let _r = check_expr(self, call.callee)
    return self.engine.fresh_var()
}

fn check_call_arg(self: &Checker, arg: &CallArgument) {
    arg.* match {
        Positional(e) => { let _r = check_expr(self, e) },
        Named(named) => { let _r = check_expr(self, named.value) },
    }
}

fn check_if(self: &Checker, if_expr: &IfExpr) Ty {
    let _r = check_expr(self, if_expr.condition)
    let then_ty = check_block(self, &if_expr.then_branch)
    let else_ty = if_expr.else_branch match {
        NoElse => Ty.Void,
        Block(b) => check_block(self, &b),
        If(nested) => check_if(self, nested),
    }
    const o = self.engine.unify(then_ty, else_ty)
    report_unify(self, &o, E_TYPE_MISMATCH, if_expr.span)
    return then_ty
}

// `S { f = v, ... }` — the literal's type is the resolved nominal `S`; each
// initializer is unified against its declared field type (so an unsuffixed
// literal resolves and a mismatch is reported). An anonymous `.{ … }` (no
// type) defers to a fresh var until record literals land.
fn check_struct_lit(self: &Checker, lit: &StructLiteralExpr) Ty {
    if lit.type_expr.is_none() {
        for i in 0..lit.fields.len {
            let _v = check_field_value(self, &lit.fields[i])
        }
        return self.engine.fresh_var()
    }
    let ty = resolve_type_expr(self, lit.type_expr.unwrap())
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

// The value of a field initializer: the explicit `f = expr`, or — for
// shorthand `S { f }` — the in-scope binding named like the field.
fn check_field_value(self: &Checker, fi: &StructFieldInit) Ty {
    if fi.value.is_some() { return check_expr(self, fi.value.unwrap()) }
    let id = IdentifierExpr { span = fi.span, name = fi.name }
    return check_identifier(self, &id)
}

// `recv.member` — when the receiver is a struct with a field of that name,
// the access yields the field's (substituted) type. Otherwise it defers to
// a fresh var: member syntax also bases UFCS calls, which resolve elsewhere.
fn check_member(self: &Checker, ma: &MemberAccessExpr) Ty {
    let recv = check_expr(self, ma.receiver)
    let fty = struct_field_lookup(self, &recv, ma.member)
    if fty.is_some() { return fty.unwrap() }
    return self.engine.fresh_var()
}

// A struct field's declared type by name. Null when the (zonked,
// one-reference-peeled) type is not a struct or has no such field. The field
// type is returned verbatim — generic field substitution lands with generics.
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
        if sd.fields[i].name == name { return Some(sd.fields[i].ty) }
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
    let out_specializations = self.results.specializations
    let out_nominals = self.nominals
    let out_functions = self.functions

    self.results.reset_side_tables()
    self.nominals = nominal_registry(self.allocator)
    self.functions = function_registry(self.allocator)

    return TypeCheckResult {
        node_types = zonked,
        resolved_ops = out_resolved_ops,
        resolved_targets = out_resolved_targets,
        instantiated_types = out_instantiated_types,
        specializations = out_specializations,
        nominals = out_nominals,
        functions = out_functions,
    }
}
