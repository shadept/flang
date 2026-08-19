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
    // True while checking a generic function's body: overload resolution
    // over unbound type params is unreliable there, so failures stay
    // silent (the reference checker re-checks per specialization instead).
    in_generic_body: bool

    // Module FQN -> the set of module FQNs whose `pub` declarations are
    // visible from it. Built once per `check_all` from the modules'
    // imports: direct imports plus the transitive `pub import` closure,
    // plus the auto-imported core prelude.
    visible_by_module: Dict(OwnedString, Set(String))

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
        in_generic_body = false,
        visible_by_module = dict(allocator),
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
    // a `0`-sized array - the parser would already have surfaced the
    // expression-evaluation error.
    let length = array_length_of(a.length)
    return self.engine.mk_array(elem, length)
}

fn array_length_of(e: &Expr) usize {
    // Array-length expressions are arbitrary integer-valued exprs -
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

fn dot_join(segs: &List(String), alloc: &Allocator?) OwnedString {
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
    let _r =self.functions.register(scheme_obj)
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
        Function(fd) => check_function_body(self, &fd),
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
        })
        params.push(ty)
    }
    let ret = fd.return_type match {
        Some(rt) => resolve_type_expr(self, &rt),
        None => Ty.Void,
    }

    let q: Set(VarId) = set(self.allocator)
    for i in 0..params.len {
        free_vars(&params[i], 0u32, &q)
    }
    free_vars(&ret, 0u32, &q)
    self.in_generic_body = q.len() > 0
    q.deinit()

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
    self.in_generic_body = false
    self.engine.exit_level()
    self.env.pop_scope()
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
        _ => self.engine.fresh_var(),
    }
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
            cmp_derived_op = null, is_ref_form = true,
        })
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
            cmp_derived_op = null, is_ref_form = false,
        })
        return p.ret
    }

    push_call_diag(self, idx.span, E_NOT_INDEXABLE,
        from_view("type does not support indexing: declare `op_index_ref(&Self, Idx) &T` or `op_index(Self, Idx) T`"))
    return self.engine.fresh_var()
}

// Resolve one indexing operator against the visible registry candidates.
// Unlike a call site this must not report on failure - the caller tries
// several shapes and reports once at the end.
fn index_operator(self: &Checker, name: String, self_ty: Ty, index_ty: Ty, span: SourceSpan) OverloadPick? {
    let vis = current_visibility(self)
    let cands = self.functions.lookup(name, &vis) match {
        FnLookFound(c) => Some(c),
        _ => null,
    }
    if cands.is_none() { return null }
    let candidates = cands.unwrap()

    let args: List(Ty) = list(2, self.allocator)
    args.push(self_ty)
    args.push(index_ty)

    // Probe first: `resolve_overload` commits its unifications and reports
    // mismatches, so a losing shape would both pollute the substitution and
    // emit a diagnostic the caller is about to supersede.
    let viable = false
    for i in 0..candidates.len {
        if probe_candidate(self, &candidates[i], &args).is_some() { viable = true }
    }
    let pick = if viable { resolve_overload(self, &candidates, &args, span) } else { null }

    args.deinit()
    candidates.deinit()
    return pick
}

// `expr as T` yields `T`; cast validity (representability, pointer
// compatibility) is a later pass, matching the reference checker.
fn check_cast(self: &Checker, c: &CastExpr) Ty {
    let _v = check_expr(self, c.operand)
    return resolve_type_expr(self, c.target)
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
        Int(_) => self.engine.fresh_var(),       // unsuffixed - context resolves
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
        Shl => lhs,
        Shr => lhs,
        UShr => lhs,
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
    let vis = current_visibility(self)
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

    let vis = current_visibility(self)
    let cands = self.functions.lookup(ma.member, &vis) match {
        FnLookFound(c) => Some(c),
        _ => null,
    }
    if cands.is_none() {
        push_call_diag(self, call.span, E_UNKNOWN_IDENT,
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
    let vis = current_visibility(self)
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

// Call-resolution diagnostics stay silent in generic bodies, where
// unbound type params make resolution unreliable (the reference checker
// re-checks those per specialization instead).
fn push_call_diag(self: &Checker, span: SourceSpan, code: String, message: OwnedString) {
    if self.in_generic_body {
        message.deinit()
        return
    }
    push_diag_e(self, span, code, message)
}

// Record the winner on the call node and return its instantiated return
// type; report when no overload matched.
fn commit_pick(self: &Checker, pick: OverloadPick?, name: String, n_args: usize, span: SourceSpan) Ty {
    return pick match {
        Some(p) => {
            self.results.record_target(node_id_of(span), ResolvedTarget.RtFunction(p.id))
            p.ret
        },
        None => {
            push_call_diag(self, span, E_NO_OVERLOAD,
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
        push_call_diag(self, span, E_NO_OVERLOAD,
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
            push_call_diag(self, span, E_NO_OVERLOAD,
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
    push_call_diag(self, span, E_NO_OVERLOAD,
        $"expression of non-function type is not callable")
    return self.engine.fresh_var()
}

// The winning overload for a call site: registry id plus instantiated
// return type.
type OverloadPick = struct {
    id: u32
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
    let f = scheme_fn_ty(self, &w.signature) match {
        Some(ft) => ft,
        None => return null,
    }
    let checked = non_variadic_arg_count(w, &f, arg_tys.len)
    for i in 0..checked {
        const o = self.engine.unify(arg_tys[i], f.params[i])
        report_unify(self, &o, E_TYPE_MISMATCH, span)
    }
    return Some(OverloadPick { id = w.id, ret = f.ret.* })
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
    let vis = current_visibility(self)
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
        for i in 0..lit.fields.len {
            let _v = check_field_value(self, &lit.fields[i])
        }
        return self.engine.fresh_var()
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
    return self.engine.fresh_var()
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
