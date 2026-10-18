// Checker driver - wires the engine, registries, env, and results into the three public phases:
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
// Expression, statement, and declaration handling all live in this file today; split into
// per-category modules when match/pattern checking lands and the dispatchers stop fitting in one
// screen. Module-level state (engine, env, ctx) is bundled into a `Checker` struct passed by
// reference to every sub-routine - no global state.

import std.allocator
import std.collections.dict
import std.collections.list
import std.collections.set
import std.collections.string_pool
import std.option
import std.string
import std.string_builder
import std.test
import std.time

import flang_core.diagnostic
import flang_core.span
import flang_parser.ast
import flang_parser.comptime
import flang_parser.cst
import flang_parser.lexer
import flang_parser.parser
import flang_parser.projector

import flang_typer.env
import flang_typer.error_codes
import flang_typer.fqn_map
import flang_typer.function_registry
import flang_typer.inference_engine
import flang_typer.inference_results
import flang_typer.interner
import flang_typer.node_id
import flang_typer.nominal_registry
import flang_typer.reporter
import flang_typer.result
import flang_typer.rtti
import flang_typer.scheme
import flang_typer.specialization
import flang_typer.template_expand
import flang_typer.type
import flang_typer.visibility
import flang_typer.well_known

// One function's lexical context: the declared return type so `ReturnStmt` can unify against it,
// and the function's name for diagnostics. Pushed onto the checker's `fn_stack` on entry, popped on
// exit.
pub type FnFrame = struct {
    name: String
    return_ty: Ty
    decl_span: SourceSpan
}

// What instantiating a generic template needs (M10): the declaration to re-check, its defining
// module, and the signature's type params in declaration order. `decl` is a shallow copy - children
// stay in the module's arena, which outlives the check.
type GenericTemplate = struct {
    // Lent by the module arena, which owns every declaration for the life of the build.
    decl: &FunctionDecl
    module: String
    tps: List(SigTypeParam) // signature type params, declaration order
}

// A re-registered signature's `Dict.set` overwrite frees the replaced template through this.
pub fn deinit(self: move GenericTemplate) {
    self.tps.deinit()
}

// var_id -> declared `$T` name for every type parameter the checker has minted - signature and body
// phases, function and nominal generics alike. For consumers that render types still holding
// type-parameter vars: the LSP's hover and inlay hints inside a generic body. Name views point into
// the module ASTs' source buffers and live as long as the checker's unit.
pub fn type_param_names(self: &Checker) &Dict(VarId, String) {
    return &self.tp_names
}

// One type-parameter binding created while resolving the current signature - a `$T` collected by
// `resolve_generic_bind`, or an associated type's path (`I.Item`, RFC-036) bound by its bounds -
// drained by `register_function_sig`. `ty` is zonked once the signature is done.
type SigTypeParam = struct {
    name: String
    ty: Ty
    // Where it is declared: the `$T`, or the contract's `type Item`.
    decl: NodeId
}

// An unsuffixed numeric literal's fresh var, held for the post-inference sweep: still unresolved
// once everything has settled means no context ever pinned the literal - E2001, matching the
// reference.
type PendingLit = struct {
    span: SourceSpan
    ty: Ty
    text: String
    is_float: bool
}

// An anonymous `.{ ... }` literal awaiting its nominal. The literal types as a fresh var the
// surrounding context binds; once inference settles, each field initializer unifies against the
// nominal's declared (substituted) field type - which is what pins unsuffixed numeric fields and
// rejects mismatched initializers.
type PendingAnon = struct {
    ty: Ty
    fields: List(AnonFieldRec)
}

// A field access on a receiver whose type had not settled when the member was checked - a lambda
// parameter that only the callee's instantiation pins. `placeholder` stands in for the field's type
// until `resolve_pending_members` looks the field up on the settled receiver and unifies.
type PendingMember = struct {
    span: SourceSpan
    recv: Ty
    member: String
    placeholder: Ty
    module: String?
}

pub fn deinit(self: move PendingAnon) {
    self.fields.deinit()
}

type AnonFieldRec = struct {
    name: String
    ty: Ty
    span: SourceSpan
}

// A committed pick of a generic overload, awaiting instantiation. The fresh vars inside `tp_binds`
// / `inst_params` / `inst_ret` zonk to concrete types once the enclosing body's inference settles;
// the post-pass then instantiates the template and rewrites the node's table entry
// (`resolved_targets` for calls, `resolved_ops` for operators) to cite the specialization.
type PendingSpec = struct {
    span: SourceSpan
    is_operator: bool
    // When set, the pick is an op_deref hop of a UFCS receiver chain (`deref_retry`): the drain
    // rewrites `receiver_derefs[span][index]` instead of the call/operator tables.
    deref_index: usize?
    // The hop sits on an argument's chain (RFC-020) rather than the receiver's.
    deref_on_arg: bool
    function_id: u32
    tp_binds: Dict(VarId, Ty) // template quantified id → call-site fresh var
    inst_params: List(Ty)
    inst_ret: Ty
    // The module whose body recorded the pick - unioned into visibility while the instantiation
    // checks, so the template body resolves overloads the call site can see (the
    // `hash()`-for-`Dict` contract).
    caller_module: String
    // Noted while a parked call was being redone. Kept out of the slot's pick log: the replay
    // re-runs the parked call itself, which notes the pick again.
    from_parked: bool
}

// The drain owns `tp_binds` and `inst_params`: it frees them when a pick is processed and carries
// them into the next pass when one is deferred, so dropping the queue must not touch them.
pub fn deinit(self: move PendingSpec) {}

// One instantiation frame's reuse bookkeeping (RFC-022 5e), pushed alongside `spec_callers`. The
// counters at frame start plus what nested work minted give the frame's OWN burns; `deps` collects
// the specializations its drain resolves, in process order; `hints` are the previous incarnation's
// deps when the frame is an in-place re-instantiation, matched by call site for nested picks whose
// provisional key cannot hit the registry. The diagnostics and parked-call watermarks decide
// whether the frame stays replayable.
type SpecFrame = struct {
    vars0: u32
    synth0: u32
    lambda0: u32
    child_vars: u32
    child_synth: u32
    child_lambda: u32
    deps: List(SpecDep)
    hints: List(SpecDep)
    diags0: usize
    calls0: usize
}

pub fn deinit(self: move SpecFrame) {
    self.deps.deinit()
    self.hints.deinit()
}

// A stream position: where the variable, synthetic-node and lambda counters stand. A carried
// specialization replays only from the exact position its frame once ran at.
type StreamPos = struct {
    v: u32
    s: u32
    l: u32
}

// One runtime context field (RFC-038), keyed by FQN in `Checker.ctx_fields`. `name` and `span` view
// the declaring module's source; `span.start` orders fields within a module.
type CtxField = struct {
    ty: Ty
    is_pub: bool
    name: String
    span: SourceSpan
}

// A context field resolved from a use: its FQN, a view valid until the next registration, and the
// field.
type CtxHit = struct {
    fqn: String
    field: CtxField
}

pub type Checker = struct {
    engine: Engine
    env: TypeEnv
    nominals: NominalRegistry
    // Type-alias bodies (expanded lazily at use) and module-level constant types, both FQN-keyed
    // with import-visibility lookup.
    aliases: FqnMap(TypeExpr)
    constants: FqnMap(Ty)
    // Runtime context fields (RFC-038), registered by the signature pass and carried like the
    // constants. Lookup is `resolve_context_field`'s: the FqnMap's first-match rule would hide an
    // ambiguity.
    ctx_fields: FqnMap(CtxField)
    functions: FunctionRegistry
    specs: SpecializationRegistry
    results: InferenceResults
    diagnostics: List(Diagnostic)
    // Compile-time context for #if condition evaluation. Host by default; a cross-target build
    // installs the target's via `set_comptime_ctx`.
    comptime: ComptimeCtx
    // Whether this demand checks `test {}` bodies, and so records the calls, overload picks and
    // instantiations they reach. Only the project's own modules are visited: a dependency's tests
    // are that project's concern. Off for a build, on for `flang test` and `flang check`.
    check_tests: bool

    // Working state - reset between modules.
    current_module: String?
    fn_stack: List(FnFrame)

    // M11 - fn_id → declared parameter list. `commit_pick` reads the
    // omitted params' default exprs from here to materialize them at the call site, and
    // named-argument resolution reads the parameter names. The wrapper struct keeps Dict's
    // element-wise deinit away from the AST-arena-owned list buffer (no-op fallback, like
    // GenericTemplate).
    fn_decl_params: Dict(u32, DeclParams)
    // Anonymous record types (`struct { … }` in type position, an unpinned `.{ … }` literal), one
    // registry entry per shape, keyed by the record `Ty` the interner canonicalises for it.
    anon_structs: Dict(Ty, NominalId)
    // Re-entrancy depth of default materialization: a default expression whose own call omits
    // defaults recurses through `check_expr`; a self-referential default would recurse forever, so
    // cap it.
    default_depth: usize
    // Nesting depth of `defer` bodies being checked - `?` is illegal inside one (E2091).
    defer_depth: usize
    // Alias names currently being expanded, innermost last. A name that reappears is a cycle
    // (E2036).
    alias_stack: List(String)
    // Set by `resolve_overload` when the winner would have been decided by an argument whose type
    // is still an open variable. The call site parks the call instead of committing (see
    // `pending_calls`).
    overload_deferred: bool
    // Calls parked that way, re-resolved once inference has finished.
    pending_calls: List(PendingCall)
    // fn_id → `#deprecated` reason, for the deprecated functions only.
    fn_deprecations: Dict(u32, String)

    // M10 - specialization state.
    // fn_id → what instantiation needs (generic functions only).
    templates: Dict(u32, GenericTemplate)
    // fn_id → its `where` bounds lowered to requirement atoms (RFC-035), with the bounds its
    // signature's types imply (RFC-036), for bounded functions only.
    fn_bounds: Dict(u32, List(BoundAtom))
    // A struct's or enum's parameter bounds (RFC-036), for bounded types only.
    nom_bounds: Dict(NominalId, NomBounds)
    // Associated-type paths (`I.Item`) by their text, each a view of its buffer in `path_bufs`:
    // binding names, template type-parameter names and `tp_names` entries view them.
    paths: Dict(String, String)
    path_bufs: List(OwnedString)
    // Set while a function signature resolves: a bounded type applied in it implies its bounds
    // (`sig_implied`), and a projection its bounds have not declared yet gets a placeholder they
    // must declare by the signature's end (`proj_pending`, checked against `sig_declared`).
    sig_open: bool
    // Set while the signature's parameter types resolve: what they imply is not reported at a call.
    sig_params_open: bool
    // Set while a parameter's own type resolves, where a contract stands for a fresh bounded type
    // parameter (RFC-035); `sig_sugar` collects those parameters' bounds.
    sugar_ok: bool
    sig_sugar: List(BoundAtom)
    // The parameter whose type is resolving, for those bounds' diagnostics.
    sugar_param: String
    sig_implied: List(BoundAtom)
    sig_declared: List(String)
    proj_pending: List(PendingProj)
    // Set while bodies are checked: a bounded type applied to settled arguments is checked at the
    // type expression.
    check_apps: bool
    // Whether some definition's fields name associated types this demand, so a copyability query
    // solves the instances inside its type first.
    assoc_defs: bool
    // Nominal id -> the spelling of its parameters' bounds, for the bounded ones. A collection that
    // spells them differently sets `bounds_changed`: what other modules' bodies and signatures
    // implied from the type is stale, as after an alias edit.
    bound_texts: Dict(NominalId, OwnedString)
    bounds_changed: bool
    // Go-to-definition edges `record_type_ref` adds, logged while `ref_logging` is on (the
    // signature and resolve passes, whose caches replay them). `ref_new` counts the ones that added
    // a target, which a signature pass's cleanliness check discounts.
    ref_log: List(TypeRefFact)
    ref_logging: bool
    // A named contract's body span (as a node id) -> its declaration's span, which `Self` inside it
    // names for go-to-definition and hover.
    self_decls: Dict(NodeId, SourceSpan)
    sig_refs: List(SigRef)
    ref_new: usize
    // Nesting depth of bound checks: satisfying a requirement resolves a call, whose candidates may
    // carry bounds of their own.
    bound_depth: usize
    // Set by `probe_candidate` when the arguments fit and only the candidate's bounds refused them.
    probe_bound_failed: bool
    // Every type-parameter var ever minted, by id, with its declared `$T` name - see
    // `type_param_names`. Grows monotonically; ids from retired demands linger harmlessly.
    tp_names: Dict(VarId, String)
    // Templates whose rigid check (RFC-029) found an ownership error, by declaration node: their
    // instantiations skip the ownership pass, so each error is reported once, at the declaration.
    rigid_flagged: Set(NodeId)
    // Set while an instantiation of a flagged template is checked.
    skip_ownership: bool
    // Set while `check_template_rigid` runs, with the template it checks and each rigid variable's
    // template variable.
    rigid_mode: bool
    rigid_fid: u32
    rigid_tvars: Dict(VarId, VarId)
    // `$T` bindings of the signature currently being registered, in declaration order.
    sig_tps: List(SigTypeParam)
    // Generic picks recorded while checking the current body scope; drained after phase 3 (and,
    // nested, after each instantiation's body check - `instantiate` swaps in a fresh list).
    pending_specs: List(PendingSpec)
    // Caller-module chain of the instantiations in progress - unioned into `current_visibility` so
    // a template body resolves overloads its call sites can see.
    spec_callers: List(String)
    // Call-site spans of the same chain, outermost first. A diagnostic raised inside a template
    // body names the caller's line, because the template is written once and the instantiation is
    // what its argument types made of it.
    spec_call_spans: List(SourceSpan)
    // Guard against runaway instantiation chains (infinitely recursive polymorphism).
    spec_depth: usize
    // Unsuffixed numeric literals awaiting the post-inference sweep.
    pending_literals: List(PendingLit)
    // Anonymous literals awaiting their nominal - resolved per body scope, before that scope's
    // specialization drain (a pinned field can be what makes a generic pick's signature concrete).
    pending_anons: List(PendingAnon)
    // Member accesses on receivers still open when checked - resolved once the body's inference and
    // its specialization drain have pinned the receiver.
    pending_members: List(PendingMember)
    // True while `resolve_pending_calls` redoes parked calls, so the picks they note are tagged.
    resolving_parked: bool
    // Overloaded function NAMES in value position (`.map(deinit)`) awaiting instantiation-time
    // resolution: once the surrounding inference pins the slot's Func shape, the overload
    // resolves against it (ticket 019 §4). Drained per body scope with
    // the other pendings.
    pending_fn_names: List(PendingFnName)

    // Module FQN -> the set of module FQNs whose `pub` declarations are visible from it. Built once
    // per `check_all` from the modules' imports: direct imports plus the transitive `pub import`
    // closure, plus the auto-imported core prelude.
    visible_by_module: Dict(OwnedString, Set(String))

    // `flang.toml`'s `[imports].global`, and which modules it applies to. `project_origin[i]` marks
    // module i as a project file; the stdlib and dependencies stay isolated from per-project
    // config, so their entries are false and `build_visibility` skips them. Both empty unless the
    // driver calls `set_project_globals`.
    project_globals: List(OwnedString)
    project_origin: List(bool)

    // Monotonic counter behind `synth_span`: gives every checker- synthesized AST node
    // (interpolation desugar) a node id no real node can collide with. Also names the desugar's
    // builder locals.
    next_synth: u32

    // RFC-014 lambdas: the open lambda literals, innermost last. `check_identifier` records an
    // outer-local read as a by-value capture on every crossed frame.
    lambda_frames: List(LambdaFrame)
    // Synthesized closure nominal -> its call signature/symbol. Global, not overlay-scoped: a
    // closure travels through `$F` slots into other bodies, which dispatch by the value's nominal
    // id.
    closures: Dict(NominalId, ClosureSig)
    // Monotonic id behind lambda/closure symbols. Advances per *check*, so a template body's lambda
    // mints a fresh symbol per instantiation.
    next_lambda: u32

    // FQN -> the id a definition held before it was taken out of the registry for this demand: the
    // declared names of modules being collected again, and every closure environment (rebuilt by
    // the body pass each demand). A definition that comes back keeps its id, so the ids in a
    // re-check are the ids in a check from cold. Cleared at the end of `check_all`; an unclaimed
    // `from_module` entry is a declaration the edit removed.
    recycled: Dict(String, RetiredName)
    // Set by `register_collected` when a registration had no retired id to reclaim - a name this
    // demand added. Read once per `check_all` to decide whether carried nominal bodies are still
    // valid.
    saw_new_name: bool

    // Module path -> the diagnostics its name-collection, body-resolution and signature passes
    // produced, replayed verbatim on a demand that reuses the module (RFC-022 section 5: a cache
    // hit replays its cached diagnostics). `nominal_diag_keys` owns the path buffers the dict's
    // keys view.
    nominal_diags: Dict(String, ModuleNomDiags)
    nominal_diag_keys: List(OwnedString)

    // Module path -> what its signature pass produced beyond the carried registries, for demands
    // that skip the pass (RFC-022 5c). `sig_cache_keys` owns the path buffers. `sig_capture` is on
    // while a module's signature pass runs; `node_of` then records each minted id into `sig_nodes`,
    // which `finish_sig_capture` moves into the cache.
    sig_caches: Dict(String, ModuleSigCache)
    sig_cache_keys: List(OwnedString)
    sig_capture: bool
    sig_nodes: List(SigNodeFact)

    // Module path -> what its body slot produced, for demands that replay the slot (RFC-022 5d).
    // `body_cache_keys` owns the path buffers. `slot_log_on` is set while a running slot's first
    // drain executes; top-level `process_pending` then logs each pick into `slot_picks`.
    // `slot_uninferable` counts the slot's E2001 uninferable picks - any makes the slot
    // uncacheable, since an unprocessed pick leaves no log entry to replay. `defaults_changed` is
    // set when a re-run signature pass's default-value texts differ from the previous demand's.
    body_caches: Dict(String, ModuleBodyCache)
    body_cache_keys: List(OwnedString)
    // Module path -> what its generic bodies look like to their rigid check, for hover: a body's
    // nodes typed by its own type parameters (`cmp: F`) rather than by one instantiation's
    // arguments. Rebuilt when the module's bodies run, carried when they replay.
    template_types: Dict(String, TemplateTypes)
    template_type_keys: List(OwnedString)
    slot_log_on: bool
    slot_picks: List(CapturedPick)
    slot_uninferable: usize
    defaults_changed: bool

    // Specialization reuse state (RFC-022 5e). `spec_frames` mirrors the instantiation stack.
    // `slot_hints` are the running slot's carried site hints; `slot_sites` collects the slot's own
    // resolutions for its cache, while `site_log_on` (a running slot's whole settlement, off during
    // a replay). `slot_new_specs` are the entries instantiated during the current slot, marked
    // non-reusable when the slot's literal sweep flags anything they minted.
    spec_frames: List(SpecFrame)
    slot_hints: List(SpecDep)
    slot_sites: List(SpecDep)
    slot_new_specs: List(SpecId)
    site_log_on: bool

}

// One module's cached diagnostics from the carried tiers. `bodies` covers the slot's capture window
// (the body pass through the fn-name resolution); what the slot's drains and parked-call resolution
// emit is regenerated live by a replay and is not cached.
pub type ModuleNomDiags = struct {
    collect: List(Diagnostic)
    resolve: List(Diagnostic)
    signatures: List(Diagnostic)
    bodies: List(Diagnostic)
    // Variables the resolve pass minted, when bounds or contract declarations made it mint more
    // than one per type parameter; a demand carrying the bodies burns as many.
    resolve_burn: u32?
    // The go-to-definition edges the resolve pass recorded (projections in fields and bounds).
    resolve_refs: List(TypeRefFact)
}

pub fn deinit(self: move ModuleNomDiags) {
    self.resolve_refs.deinit()
    self.collect.deinit()
    self.resolve.deinit()
    self.signatures.deinit()
    self.bodies.deinit()
}

// One captured node from a module's signature pass: the id, the span it was minted from, and -
// filled in at harvest, once the demand's final zonk has run - the type recorded for it, if any.
// Replaying the facts reproduces the pass's span and node-type entries without running it.
pub type SigNodeFact = struct {
    node: NodeId
    span: SourceSpan
    ty: Ty?
}

// What one module's signature pass produced, cached for demands that skip the pass. `var_burn` is
// how many engine variables the pass minted - a skipping demand mints the same count so every later
// phase's variable stream matches a cold check's. `lit_tys` holds the pass's unsuffixed-literal
// variables between capture and harvest; one still unresolved at harvest would need its E2001
// replayed, so the module is marked uncacheable instead. `cacheable` is false whenever the pass
// recorded anything beyond node types and spans (a call in a default value, a lambda, an anonymous
// literal) - such a module re-runs its pass every demand.
pub type ModuleSigCache = struct {
    facts: List(SigNodeFact)
    var_burn: usize
    // The engine's variable counter when the pass started. The burned and carried variable ids are
    // absolute, so the cache replays only from this exact position - an upstream edit that shifts
    // it forces a re-run, which re-anchors the cache.
    vars_at_start: u32
    lit_tys: List(Ty)
    // The go-to-definition edges the pass recorded (projections).
    refs: List(TypeRefFact)
    // The source text of each default-value expression, in declaration order. A re-run whose texts
    // differ from the previous run's invalidates every carried body: callers cached the callee's
    // default AST, and a scheme compare cannot see a default's value change. Empty when the caller
    // supplied no sources (test fixtures), which skips the comparison.
    default_texts: List(OwnedString)
    cacheable: bool
    // True between capture and this demand's harvest.
    fresh: bool
}

pub fn deinit(self: move ModuleSigCache) {
    self.facts.deinit()
    self.refs.deinit()
    self.lit_tys.deinit()
    self.default_texts.deinit()
}

// ─────────────────────────────────────────────────────────────────────
// Carried bodies (RFC-022 5d) - the per-module body cache. One entry per module, holding everything
// the module's slot wrote, so a demand can replay the slot instead of running it. Facts are
// harvested with FINAL values (the raw recordings cite engine bindings that die with the demand
// that made them); the slot's drains and parked-call resolution are replayed LIVE from the captured
// picks and calls, which is what recreates the demand's specializations and re-pins the module's
// burned variables in the order the cold drain pinned them.
// ─────────────────────────────────────────────────────────────────────

pub type NodeTyFact = struct {
    node: NodeId
    ty: Ty
}

pub type NodeSpanFact = struct {
    node: NodeId
    span: SourceSpan
}

pub type NodeTargetFact = struct {
    node: NodeId
    target: ResolvedTarget
}

pub type NodeAdaptFact = struct {
    node: NodeId
    adapt: ReceiverAdapt
}

pub type NodeOpFact = struct {
    node: NodeId
    op: ResolvedOperator
}

pub type NodeBlockFact = struct {
    node: NodeId
    block: &BlockExpr
}

pub type NodeLambdaFact = struct {
    node: NodeId
    info: LambdaInfo
}

pub fn deinit(self: move NodeLambdaFact) {
    self.info.deinit()
}

pub type NodeExprsFact = struct {
    node: NodeId
    exprs: List(&Expr)
}

pub fn deinit(self: move NodeExprsFact) {
    self.exprs.deinit()
}

pub type NodeDerefsFact = struct {
    node: NodeId
    chain: List(ResolvedTarget)
}

pub fn deinit(self: move NodeDerefsFact) {
    self.chain.deinit()
}

// One top-level generic pick as the drain processed it, types zonked at process time. A replay
// re-runs these in process order: a handle that was already concrete stays so, and one that still
// cited an open variable re-resolves through the bindings the replayed instantiations before it
// re-made - the same state the cold drain walked through.
pub type CapturedPick = struct {
    span: SourceSpan
    is_operator: bool
    deref_index: usize?
    // The hop sits on an argument's chain rather than the receiver's (RFC-020).
    deref_on_arg: bool
    function_id: u32
    tp_binds: Dict(VarId, Ty)
    inst_params: List(Ty)
    inst_ret: Ty
    caller_module: String
}

pub fn deinit(self: move CapturedPick) {
    self.tp_binds.deinit()
    self.inst_params.deinit()
}

// One module's cached body slot. `keys` holds the capture window's table keys between capture and
// harvest; harvest turns them into the fact lists and leaves `keys` empty. The counters anchor the
// cache to its position in the variable, synthetic-node and lambda streams, exactly like the
// signature cache's `vars_at_start`.
pub type ModuleBodyCache = struct {
    vars_at_start: u32
    var_burn: usize
    synth_at_start: u32
    synth_burn: u32
    lambda_at_start: u32
    lambda_burn: u32
    keys: CapturedKeys
    types: List(NodeTyFact)
    spans: List(NodeSpanFact)
    targets: List(NodeTargetFact)
    ops: List(NodeOpFact)
    desugars: List(NodeBlockFact)
    lambdas: List(NodeLambdaFact)
    closures: List(ClosureFact)
    default_args: List(NodeExprsFact)
    arg_lists: List(NodeExprsFact)
    derefs: List(NodeDerefsFact)
    arg_derefs: List(NodeDerefsFact)
    adapts: List(NodeAdaptFact)
    picks: List(CapturedPick)
    calls: List(PendingCall)
    // Every top-level pick the slot's settlement resolved, in process order, with the
    // specialization it landed on - the replay's reuse hints (RFC-022 5e): a pick whose provisional
    // key cannot match a carried entry's stored final key re-lands on its id by call site.
    spec_sites: List(SpecDep)
    cacheable: bool
    fresh: bool
}

pub fn deinit(self: move ModuleBodyCache) {
    self.spec_sites.deinit()
    self.keys.deinit()
    self.types.deinit()
    self.spans.deinit()
    self.targets.deinit()
    self.ops.deinit()
    self.desugars.deinit()
    self.lambdas.deinit()
    self.closures.deinit()
    self.default_args.deinit()
    self.arg_lists.deinit()
    self.derefs.deinit()
    self.arg_derefs.deinit()
    self.adapts.deinit()
    self.picks.deinit()
    for pc in self.calls.drain() {
        pc.arg_tys.deinit()
        pc.pos_exprs.deinit()
    }
    self.calls.deinit()
}

// A declaration's parameter list, shared with the AST (M11 defaults). Deliberately no deinit: the
// list buffer lives in the module arena.
type DeclParams = struct {
    params: List(FunctionParam)
}

pub fn deinit(self: move DeclParams) {
    self.params.deinit()
}

// A call whose overload choice was arbitrated by an argument that had not settled yet. Everything
// needed to redo the resolution once it has is captured here; the AST node itself supplies the
// argument expressions for `materialize_arg_list`.
type PendingCall = struct {
    span: SourceSpan
    name: String
    call: &CallExpr
    arg_tys: List(Ty)
    pos_exprs: List(&Expr)
    // 1 when a UFCS receiver occupies `arg_tys[0]`.
    recv_extra: usize
    // The receiver's adapted value <-> &T shape, for the same in-set adaptation the first
    // resolution would have used.
    alt_recv: Ty?
    module: String?
}

// The two lists outlive the entry: `pending_calls` is drained into the specialization pass, which
// reads the spans out of a copy taken before the drain. Freeing here is a use-after-free.
pub fn deinit(self: move PendingCall) {}

// One open lambda literal being checked. `boundary` is the scope index of the lambda's own
// parameter scope: a name found at a shallower index is an outer local, i.e. a capture.
type LambdaFrame = struct {
    boundary: usize
    lam_span: SourceSpan
    captures: List(CaptureRec)
}

pub fn deinit(self: move LambdaFrame) {
    self.captures.deinit()
}

// One overloaded-name-as-value site: the node, the fresh var its slot got, the name, and the module
// whose visibility resolves it.
type PendingFnName = struct {
    span: SourceSpan
    ty: Ty
    name: String
    module: String?
}

pub fn checker() Checker {
    return .{
        engine = engine(),
        env = type_env(),
        nominals = nominal_registry(),
        aliases = fqn_map(),
        constants = fqn_map(),
        ctx_fields = fqn_map(),
        functions = function_registry(),
        specs = specialization_registry(),
        results = inference_results(),
        diagnostics = list(0),
        comptime = host_ctx(),
        check_tests = false,
        current_module = null,
        fn_stack = list(0),
        fn_decl_params = dict(),
        anon_structs = dict(),
        default_depth = 0usize,
        defer_depth = 0usize,
        alias_stack = list(0),
        overload_deferred = false,
        pending_calls = list(0),
        fn_deprecations = dict(),
        templates = dict(),
        fn_bounds = dict(),
        nom_bounds = dict(),
        paths = dict(),
        path_bufs = list(0),
        sig_open = false,
        sig_params_open = false,
        sugar_ok = false,
        sig_sugar = list(0),
        sugar_param = "",
        sig_implied = list(0),
        sig_declared = list(0),
        proj_pending = list(0),
        check_apps = false,
        assoc_defs = false,
        bound_texts = dict(),
        bounds_changed = false,
        ref_log = list(0),
        ref_logging = false,
        self_decls = dict(),
        sig_refs = list(0),
        ref_new = 0usize,
        bound_depth = 0usize,
        probe_bound_failed = false,
        tp_names = dict(),
        rigid_flagged = set(),
        skip_ownership = false,
        rigid_mode = false,
        rigid_fid = 0u32,
        rigid_tvars = dict(),
        sig_tps = list(0),
        pending_specs = list(0),
        spec_callers = list(0),
        spec_call_spans = list(0),
        spec_depth = 0usize,
        pending_literals = list(0),
        pending_anons = list(0),
        pending_members = list(0),
        resolving_parked = false,
        pending_fn_names = list(0),
        visible_by_module = dict(),
        project_globals = list(0),
        project_origin = list(0),
        next_synth = 0u32,
        lambda_frames = list(0),
        closures = dict(),
        next_lambda = 0u32,
        recycled = dict(),
        saw_new_name = false,
        nominal_diags = dict(),
        nominal_diag_keys = list(0),
        sig_caches = dict(),
        sig_cache_keys = list(0),
        sig_capture = false,
        sig_nodes = list(0),
        body_caches = dict(),
        body_cache_keys = list(0),
        template_types = dict(),
        template_type_keys = list(0),
        slot_log_on = false,
        slot_picks = list(0),
        slot_uninferable = 0usize,
        defaults_changed = false,
        spec_frames = list(0),
        slot_hints = list(0),
        slot_sites = list(0),
        slot_new_specs = list(0),
        site_log_on = false,
    }
}

// Ready this checker for another demand over the same module set.
//
// What survives is what the previous check registered by stable key: the nominal registry -
// declared names WITH their resolved bodies, the anonymous-record definitions and the map that
// interns them - the function registry with its schemes, templates, declared parameter lists,
// deprecations and bounds, the type-parameter bounds, the associated-type path names, the constant
// types, the alias bodies, the retired closure-environment ids awaiting reclamation (`recycled`,
// see the end of `check_all`), and the per-module caches of the carried tiers (diagnostics and
// signature facts). The carried `Ty` handles index the type table, which the caller adopts back out
// of the previous result (`adopt_interner`) so they stay resolvable.
//
// Everything else a check computes is dropped: it names variables of the engine that inferred it,
// and that engine goes.
//
// The carry list is the fields moved onto the replacement below; `checker` and `deinit` enumerate
// the rest.
pub fn begin_demand(self: &Checker) {
    let noms = replace(&self.nominals, nominal_registry())
    let aliases = replace(&self.aliases, fqn_map())
    let consts = replace(&self.constants, fqn_map())
    let ctx_fields = replace(&self.ctx_fields, fqn_map())
    let fns = replace(&self.functions, function_registry())
    let tmpls = replace(&self.templates, dict())
    let bounds = replace(&self.fn_bounds, dict())
    let nbounds = replace(&self.nom_bounds, dict())
    let paths = replace(&self.paths, dict())
    let btexts = replace(&self.bound_texts, dict())
    let sdecls = replace(&self.self_decls, dict())
    let path_bufs = replace(&self.path_bufs, list(0))
    let decl_params = replace(&self.fn_decl_params, dict())
    let deprecations = replace(&self.fn_deprecations, dict())
    let anons = replace(&self.anon_structs, dict())
    let recycled = replace(&self.recycled, dict())
    let nom_diags = replace(&self.nominal_diags, dict())
    let nom_diag_keys = replace(&self.nominal_diag_keys, list(0))
    let sig_caches = replace(&self.sig_caches, dict())
    let sig_cache_keys = replace(&self.sig_cache_keys, list(0))
    let body_caches = replace(&self.body_caches, dict())
    let body_cache_keys = replace(&self.body_cache_keys, list(0))
    let ttypes = replace(&self.template_types, dict())
    let ttype_keys = replace(&self.template_type_keys, list(0))
    const ct = self.comptime

    let next = checker()
    // Each table the fresh checker built is released as the carried one takes its place.
    install(&next.nominals, noms)
    install(&next.aliases, aliases)
    install(&next.constants, consts)
    install(&next.ctx_fields, ctx_fields)
    install(&next.functions, fns)
    install(&next.templates, tmpls)
    install(&next.fn_bounds, bounds)
    install(&next.nom_bounds, nbounds)
    install(&next.paths, paths)
    install(&next.bound_texts, btexts)
    install(&next.self_decls, sdecls)
    install(&next.path_bufs, path_bufs)
    install(&next.fn_decl_params, decl_params)
    install(&next.fn_deprecations, deprecations)
    install(&next.anon_structs, anons)
    install(&next.recycled, recycled)
    install(&next.nominal_diags, nom_diags)
    install(&next.nominal_diag_keys, nom_diag_keys)
    install(&next.sig_caches, sig_caches)
    install(&next.sig_cache_keys, sig_cache_keys)
    install(&next.body_caches, body_caches)
    install(&next.body_cache_keys, body_cache_keys)
    install(&next.template_types, ttypes)
    install(&next.template_type_keys, ttype_keys)
    next.comptime = ct
    // Replaces the checker and releases what it still owns: the tables carried above already left,
    // so what goes is this demand's own.
    install(self, next)
}

// Start this demand's result tables at the previous demand's final sizes - a re-demand rewrites
// nearly every entry, and beginning at the target size skips the doubling rehashes on the replay
// path. Call between `begin_demand` and `check_all`.
pub fn presize_results(self: &Checker, sizes: &TableCaps) {
    self.results.presize_tables(sizes)
}

// Install the specialization registry carried from the previous demand's result (RFC-022 5e).
// Entries whose validity the demand confirms are reused in place of their body re-check; the rest
// re-instantiate at the ids they hold, and whatever the demand never touches is swept.
pub fn adopt_specs(self: &Checker, reg: move SpecializationRegistry) {
    install(&self.specs, reg)
}

// Install a type table carried from the previous demand's result, so the handles baked into the
// carried registry stay valid. A pristine table (an empty result's stand-in) carries nothing and is
// dropped in favour of the engine's own seeded one.
pub fn adopt_interner(self: &Checker, it: move TypeInterner) {
    if it.is_pristine() {
        it.deinit()
        return
    }
    self.engine.set_interner(it)
}

// Retire the definitions of every module in `retiring` - declared type names and the generated
// declarations expansion appended to them - so their sources can register them again. Each id is
// remembered against its FQN in `recycled`: a definition that survives the edit is re-registered at
// the id it had, one that is gone leaves a hole, and a new one mints a fresh id.
//
// One pass over the registry covers the whole set: it is keyed by id and by FQN, with no index by
// module.
fn retire_names(self: &Checker, retiring: &Set(String)) {
    let doomed: List(NominalId) = list(0)
    defer doomed.deinit()
    for i in 0..(self.nominals.next_id as usize) {
        const id = i as NominalId
        const found = self.nominals.find(id)
        if found.is_none() {
            continue
        }
        if !retiring.contains(nominal_module(found.unwrap())) {
            continue
        }
        doomed.push(id)
    }
    for id in doomed {
        let def = self.nominals.get(id)
        const fqn = nominal_fqn(def)
        self.recycled.set(fqn, RetiredName { id = id, fqn = fqn, from_module = true })
        self.nominals.evict(id)
    }
}

// Register a definition under a stable key, at the id it held before it was retired when it had
// one. A registration with no retired id to reclaim is a name this demand added - noted, because
// carried bodies stay valid only while the name set they resolved against holds still. The alias
// registry holds the body the module arena owns.
fn register_alias(self: &Checker, fqn_owned: move OwnedString, body: &TypeExpr) {
    self.aliases.register(fqn_owned, body.*)
}

fn register_collected(self: &Checker, def: move NominalDef, fqn_owned: move OwnedString) NominalId {
    const previous = self.recycled.remove(fqn_owned.view)
    if previous.is_none() {
        self.saw_new_name = true
        return self.nominals.register(def, fqn_owned)
    }
    const prev = previous.unwrap()
    // The remembered view is the registry's own FQN buffer, which `evict` leaves in place - so the
    // id goes back under the string already owned and the caller's copy is dropped.
    fqn_owned.deinit()
    self.nominals.register_at(prev.id, def, prev.fqn)
    return prev.id
}

// A definition taken out of the registry so its source can register it again: the id it held, the
// registry's own FQN buffer, and whether it came from a module retirement (a declared or generated
// name) as opposed to a closure environment. Only the former count as removed declarations when
// they go unclaimed.
type RetiredName = struct {
    id: NominalId
    fqn: String
    from_module: bool
}

pub fn deinit(self: move Checker) {
    self.engine.deinit()
    self.env.deinit()
    self.nominals.deinit()
    self.aliases.deinit()
    self.constants.deinit()
    self.ctx_fields.deinit()
    self.functions.deinit()
    self.specs.deinit()
    self.results.deinit()
    self.diagnostics.deinit()
    self.fn_stack.deinit()
    self.alias_stack.deinit()
    self.pending_calls.deinit()
    self.fn_deprecations.deinit()
    self.fn_bounds.deinit()
    self.nom_bounds.deinit()
    self.paths.deinit()
    self.path_bufs.deinit()
    self.bound_texts.deinit()
    self.ref_log.deinit()
    self.rigid_tvars.deinit()
    self.self_decls.deinit()
    self.sig_refs.deinit()
    self.sig_implied.deinit()
    self.sig_sugar.deinit()
    self.sig_declared.deinit()
    self.proj_pending.deinit()
    self.fn_decl_params.deinit()
    self.anon_structs.deinit()
    self.sig_tps.deinit()
    self.tp_names.deinit()
    self.rigid_flagged.deinit()
    self.pending_specs.deinit()
    self.spec_callers.deinit()
    self.spec_call_spans.deinit()
    self.pending_literals.deinit()
    self.pending_anons.deinit()
    self.pending_members.deinit()
    self.pending_fn_names.deinit()
    self.visible_by_module.deinit()
    self.project_globals.deinit()
    self.project_origin.deinit()
    self.lambda_frames.deinit()
    self.closures.deinit()
    self.recycled.deinit()
    self.nominal_diags.deinit()
    self.nominal_diag_keys.deinit()
    self.sig_caches.deinit()
    self.sig_cache_keys.deinit()
    self.sig_nodes.deinit()
    self.body_caches.deinit()
    self.body_cache_keys.deinit()
    self.template_types.deinit()
    self.template_type_keys.deinit()
    self.slot_picks.deinit()
    self.spec_frames.deinit()
    self.slot_hints.deinit()
    self.slot_sites.deinit()
    self.slot_new_specs.deinit()
}

// ─────────────────────────────────────────────────────────────────────
// Resolving TypeExpr → Ty
//
// The parser's AST has a `TypeExpr` enum that mirrors source-level type syntax: `Named`, `Generic`,
// `Reference`, `Optional`, `Array`, `Slice`, `Tuple`, `Function`, anonymous struct, anonymous enum,
// `GenericBind` (the `$T` introducer), and `Error`. The resolver walks this and produces a `Ty`.
//
// Type aliases resolve transparently here: `resolve_named` consults the alias registry after the
// primitive and nominal lookups and expands the stored body lazily, so alias chains and
// cross-module targets resolve regardless of declaration order.
// ─────────────────────────────────────────────────────────────────────

pub fn resolve_type_expr(self: &Checker, te: &TypeExpr) Ty {
    // A contract stands for a type parameter at a parameter's type, behind `&` and `[]` (RFC-035);
    // inside any other type it would need a value of the contract.
    const sugar = self.sugar_ok
    const passes = te.* match {
        Named(_) => true
        Reference(_) => true
        Slice(_) => true
        Contract(_) => true
        Combined(_) => true
        _ => false
    }
    self.sugar_ok = sugar and passes
    const out = resolve_type_node(self, te)
    self.sugar_ok = sugar
    return out
}

fn resolve_type_node(self: &Checker, te: &TypeExpr) Ty {
    return te.* match {
        Named(n) => resolve_named(self, &n, te)
        Reference(r) => resolve_reference(self, &r)
        Optional(o) => resolve_optional(self, &o)
        Array(a) => resolve_array(self, &a)
        Slice(s) => resolve_slice(self, &s)
        Tuple(t) => resolve_tuple(self, &t)
        Function(f) => resolve_function(self, &f)
        GenericBind(g) => resolve_generic_bind(self, &g)
        AnonStruct(a) => resolve_anon_struct_type(self, &a)
        Contract(c) => contract_param(self, te, "contract", c.span)
        Combined(c) => contract_param(self, te, "contract", c.span)
        Projection(p) => resolve_projection(self, &p)
        _ => TY_ERROR
    }
}

// A contract where a parameter's type is written (RFC-035): a fresh type parameter bounded by it,
// one per occurrence, so `src: Reader` is `src: $R where R: Reader`. The occurrence's span names
// the parameter, and a body check or an instantiation binds that name as it binds a `$T`. Anywhere
// else a value of the contract would be needed: E2138.
fn contract_param(self: &Checker, te: &TypeExpr, label: String, span: SourceSpan) Ty {
    if !self.sugar_ok {
        const hint = if label == "contract" { "..." } else { label }
        push_diag_e(
            self,
            span,
            E_CONTRACT_VALUE,
            $"a contract has no values - in a parameter's type it stands for a bounded type parameter; elsewhere bound one: `$T where T: {hint}`",
        )
        return TY_ERROR
    }
    const at = $"@{span.start}"
    const name = intern_path(self, label, at.view)
    at.deinit()
    const b = self.env.lookup(name)
    if b.is_some() and b.unwrap().is_type_param {
        return self.engine.specialize(&b.unwrap().scheme)
    }
    if !self.sig_open {
        push_diag_e(
            self,
            span,
            E_CONTRACT_VALUE,
            from_view(
                "a contract stands for a type parameter only in a function's own parameter types",
            ),
        )
        return TY_ERROR
    }
    const v = self.engine.fresh_var()
    bind_type_name(self, name, v, span)
    ty_node(self, v) match {
        NVar(tv) => self.tp_names.set(tv.id, label)
        _ => {}
    }
    self.sig_tps.push(SigTypeParam { name = name, ty = v, decl = self.node_of(span) })
    // Diagnostics name the parameter (`it: Iter`) and its associated types by the contract
    // (`Iter.Item`); the bindings keep the occurrence's own name.
    self.sugar_ok = false
    let members: List(Member) = list(0)
    lower_bound(self, v, te, self.sugar_param, "", span, &self.sig_sugar, &members, 0usize)
    for &m in members {
        bind_member(self, intern_path(self, name, m.name), m.ty, span, true, m.decl)
        ty_node(self, self.engine.resolve(m.ty)) match {
            NVar(mv) => self.tp_names.set(mv.id, intern_path(self, label, m.name))
            _ => {}
        }
    }
    members.deinit()
    self.sugar_ok = true
    return v
}

// Whether `name` is a declared contract or combination of contracts.
fn names_contract(self: &Checker, name: String) bool {
    const body = contract_body(self, name)
    return body.is_some() and is_contract_body(body.unwrap())
}

// `struct { x: i32, y: i32 }` in type position - a structural record. Generic anonymous structs are
// not a thing the corpus uses; a parameterised one falls back to `Error` rather than silently
// dropping the parameters.
fn resolve_anon_struct_type(self: &Checker, a: &AnonStructType) Ty {
    if a.generics.len > 0 {
        return TY_ERROR
    }
    let fields: List(Field) = list(a.fields.len)
    for i in 0..a.fields.len {
        fields.push(Field {
            name = a.fields[i].name,
            ty = resolve_type_expr(self, a.fields[i].type_expr),
            decl_span = a.fields[i].span,
            owned = a.fields[i].owned,
        })
    }
    return anon_struct_ty(self, fields, a.span)
}

// Intern an anonymous record as a synthesized nominal, keyed by its exact structure: two spellings
// of the same record are ONE registry entry, so layout, member access and lowering all take the
// ordinary nominal path.
//
// The key is the record `Ty` the interner canonicalises for those fields, which counts field types
// as well as names, so `struct { v: i32 }` and `struct { v: String }` stay distinct.
fn anon_struct_ty(self: &Checker, fields: move List(Field), span: SourceSpan) Ty {
    const key = self.engine.interner.record_of(&fields)

    let no_args: List(Ty) = list(0)
    let found = self.anon_structs.get(key)
    if found.is_some() {
        const id = found.unwrap()
        fields.deinit()
        return mk_nominal(self, id, no_args)
    }

    // The registry FQN is a bare counter: no rendering of a record shape survives C identifier
    // mangling. Interning happens through `anon_structs`.
    let empty_tps: List(VarId) = list(0)
    let nid = self.nominals.register(
        NominalDef.NomStruct(StructDef {
            fqn = "",
            module = "",
            is_pub = true,
            type_params = move empty_tps,
            assoc_params = list(0),
            fields = move fields,
            decl_span = span,
            deprecation = null,
            is_simd = false,
            is_foreign = false,
        }),
        $"__anon_{self.nominals.next_id}",
    )
    self.anon_structs.set(key, nid)
    return mk_nominal(self, nid, no_args)
}

// `te` is the `Named` node `n` came from.
fn resolve_named(self: &Checker, n: &NamedType, te: &TypeExpr) Ty {
    if n.assoc_args.len > 0 and !names_contract(self, n.name) {
        push_diag_e(
            self,
            n.assoc_args[0].span,
            E_BAD_ASSOC_ARG,
            from_view(
                "`Name = T` and `Name: Bound` constrain a contract's associated type, and belong in a bound",
            ),
        )
        return TY_ERROR
    }
    // Primitive?
    let prim = prim_from_name(n.name)
    if prim.is_some() {
        return prim_of(prim.unwrap())
    }

    // Builtin non-primitive types.
    if n.name == "void" {
        return TY_VOID
    }
    if n.name == "never" {
        return TY_NEVER
    }

    // A type parameter in scope shadows every nominal - it is the innermost binding. Without this,
    // a project type named `E` captures the stdlib's `enum(T, E)` payload declarations through the
    // program-wide nominal fallback below, poisoning the registry for the whole compilation.
    let tp = self.env.lookup(n.name)
    if tp.is_some() {
        let b = tp.unwrap()
        if b.is_type_param {
            const t = self.engine.specialize(&b.scheme)
            record_type_ref(self, n.span, n.name)
            return t
        }
    }

    // Nominal?
    let vis = current_visibility(self)
    defer vis.deinit()
    let look = self.nominals.lookup(n.name, &vis)

    let found_id: NominalId? = look match {
        NomLookFound(id) => Some(id)
        _ => null
    }
    if found_id.is_some() {
        warn_deprecated_type(self, found_id.unwrap(), n.name, n.span)
        record_nominal_ref(self, head_span(n.span, n.name.len), found_id.unwrap())
        let args = resolve_generic_args(self, n)
        apply_nominal_bounds(self, found_id.unwrap(), &args, n.name, n.span)
        return mk_nominal(self, found_id.unwrap(), args)
    }

    // Alias? Expand its stored body lazily. Resolving the body here (rather than at registration)
    // handles alias chains and cross-module targets without ordering concerns. ponytail:
    // non-generic aliases only; no cycle guard (the self-host sources have none). Generic aliases
    // and cycle detection are follow-ups.
    let alias_body = self.aliases.lookup_ref(n.name, &vis)
    if alias_body.is_some() {
        // `type A = B` / `type B = A`: expanding either one reaches itself, so the expansion never
        // terminates (E2036). The names currently being expanded are the cycle witness.
        if contains_view(&self.alias_stack, n.name) {
            push_diag_e(
                self,
                n.span,
                E_CYCLIC_ALIAS,
                $"type alias `{n.name}` is cyclic - it expands to itself",
            )
            return TY_ERROR
        }
        let body = alias_body.unwrap()
        if is_contract_body(body) {
            return contract_param(self, te, n.name, n.span)
        }
        self.alias_stack.push(n.name)
        const out = resolve_type_expr(self, body)
        let _p = self.alias_stack.pop()
        return out
    }

    // A registered type outside the import scope still resolves: the reference compiler resolves
    // type names program-wide regardless of imports, and the stdlib depends on it. Import-strict
    // type visibility is a future tightening (identifiers stay strict).
    let hidden_info: NomHiddenInfo? = look match {
        NomLookHidden(info) => Some(info)
        _ => null
    }
    if hidden_info.is_some() {
        let info = hidden_info.unwrap()
        let args = resolve_generic_args(self, n)
        apply_nominal_bounds(self, info.id, &args, n.name, n.span)
        return mk_nominal(self, info.id, args)
    }

    if n.name == SELF_NAME {
        push_diag_e(
            self,
            n.span,
            E_SELF_OUTSIDE,
            from_view(
                "`Self` names the type being declared, and is only valid inside a named struct, enum or contract body",
            ),
        )
        return TY_ERROR
    }
    push_diag_e(self, n.span, E_UNKNOWN_TYPE, $"unknown type `{n.name}`")
    return TY_ERROR
}

// W2001: naming a `#deprecated` struct or enum. Fires at every use site, including inside the
// defining module (reference parity - the point is to surface every remaining reference).
fn warn_deprecated_type(self: &Checker, id: NominalId, name: String, span: SourceSpan) {
    let dep = self.nominals.get(id).* match {
        NomStruct(sd) => sd.deprecation
        NomEnum(ed) => ed.deprecation
    }
    if dep.is_none() {
        return
    }
    let msg = dep.unwrap()
    if msg.len == 0 {
        push_diag_w(self, span, W_DEPRECATED, $"type `{name}` is deprecated")
    } else {
        push_diag_w(self, span, W_DEPRECATED, $"type `{name}` is deprecated: {msg}")
    }
}

fn resolve_generic_args(self: &Checker, n: &NamedType) List(Ty) {
    const sugar = self.sugar_ok
    self.sugar_ok = false
    let out: List(Ty) = list(n.generic_args.len)
    for &arg in n.generic_args {
        out.push(resolve_type_expr(self, arg))
    }
    self.sugar_ok = sugar
    return out
}

fn resolve_reference(self: &Checker, r: &ReferenceType) Ty {
    let inner = resolve_type_expr(self, r.inner)
    // A function type is already pointer-sized; `&fn(...)` would be a pointer to a pointer nothing
    // can produce (E2006).
    let is_fn = ty_node(self, inner) match { NFunc(_) => true, _ => false }
    if is_fn {
        push_diag_e(
            self,
            r.span,
            E_REF_TO_FN,
            from_view(
                "cannot take a reference to a function type - function types are already pointer-sized",
            ),
        )
        return TY_ERROR
    }
    return self.engine.mk_ref(inner)
}

fn resolve_optional(self: &Checker, o: &OptionalType) Ty {
    let inner = resolve_type_expr(self, o.inner)
    let opt_id = self.nominals.by_fqn.get(FQN_OPTION)
    if opt_id.is_none() {
        return TY_ERROR
    }
    let args: List(Ty) = list(1)
    args.push(inner)
    return mk_nominal(self, opt_id.unwrap(), args)
}

fn resolve_array(self: &Checker, a: &ArrayType) Ty {
    let elem = resolve_type_expr(self, a.element)
    // Array length is an expr in the parser AST; for first slice we only handle integer-literal
    // lengths. Anything else surfaces as a `0`-sized array - the parser would already have surfaced
    // the expression-evaluation error.
    let length = array_length_of(a.length)
    return self.engine.mk_array(elem, length)
}

// A declared array length. Only plain integer-literal lengths evaluate (the only form the corpus
// writes); anything else stays 0 until a const_eval pass exists. M10 made this load-bearing: array
// literals now type as `[T; len]`, so a declared `u8[1024]` must size to 1024 or every
// literal-vs-declared unify fails on length.
fn array_length_of(e: &Expr) usize {
    return literal_count_of(e) match {
        Some(n) => n
        None => 0usize
    }
}

fn resolve_slice(self: &Checker, s: &SliceType) Ty {
    return slice_of(self, resolve_type_expr(self, s.element))
}

// `T[]` - the well-known `Slice(T)` instantiation. `Error` when the stdlib's slice type is not
// registered (a source set without `core`).
fn slice_of(self: &Checker, elem: Ty) Ty {
    let slice_id = self.nominals.by_fqn.get(FQN_SLICE)
    if slice_id.is_none() {
        return TY_ERROR
    }
    let args: List(Ty) = list(1)
    args.push(elem)
    return mk_nominal(self, slice_id.unwrap(), args)
}

// A declared parameter's type. A variadic `..xs: T` is a `Slice(T)` inside the body and at the call
// site - the declaration spells the ELEMENT type (spec 4.2, reference parity); callers pack their
// surplus arguments into an array that decays to it.
fn param_ty(self: &Checker, p: &FunctionParam) Ty {
    let ty = resolve_type_expr(self, p.type_expr)
    if p.is_variadic {
        return slice_of(self, ty)
    }
    return ty
}

fn resolve_tuple(self: &Checker, t: &TupleType) Ty {
    let elems: List(Ty) = list(t.elements.len)
    for &e in t.elements {
        elems.push(resolve_type_expr(self, e))
    }
    return mk_tuple(self, elems)
}

fn resolve_function(self: &Checker, f: &FunctionType) Ty {
    let params: List(Ty) = list(f.params.len)
    let moves = 0usize
    for i in 0..f.params.len {
        const pt = resolve_type_expr(self, &f.params[i])
        const declared = i < f.param_moves.len and f.param_moves[i]
        moves = moves | move_bit_of(self, i, declared, pt, f.span)
        params.push(pt)
    }
    let ret = f.return_type match {
        Some(rt) => resolve_type_expr(self, rt)
        None => TY_VOID
    }
    return self.engine.mk_func(params, ret, moves)
}

// Parameter `i`'s bit in a function type's `move` mask: zero unless it is declared `move`. A `move`
// over a reference (rule 5) or past what the mask carries is E2130 and contributes nothing. `&move
// T` says the callee may take the value out of the caller's slot, so long as it leaves one behind.
// It is the only mode that empties storage its caller keeps, so it is declared in `core` alone and
// everything else reaches it through `swap` and `replace`.
fn check_slot_param(self: &Checker, p: &FunctionParam) {
    if !p.is_slot {
        return
    }
    const is_ref = p.type_expr.* match { Reference(_) => true, _ => false }
    if !is_ref {
        return
    }
    if in_core_module(self) {
        return
    }
    push_diag_e(
        self,
        p.span,
        E_SLOT_OUTSIDE_CORE,
        from_view(
            "`&move` parameters are declared in the core library only - `core.slice`'s `swap` and `replace` are how a value leaves a slot its caller keeps",
        ),
    )
}

// Whether the module being checked is part of the core library.
fn in_core_module(self: &Checker) bool {
    if self.current_module.is_none() {
        return false
    }
    const m = self.current_module.unwrap()
    return m == "core" or m.starts_with("core.")
}

fn move_bit_of(self: &Checker, i: usize, declared: bool, ty: Ty, span: SourceSpan) usize {
    if !declared {
        return 0usize
    }
    const is_ref = ty_node(self, self.engine.resolve(ty)) match { NRef(_) => true, _ => false }
    if is_ref {
        push_diag_e(
            self,
            span,
            E_MOVE_REF_PARAM,
            from_view(
                "`move` on a reference parameter: a reference is copyable, and owning it says nothing about the value it refers to",
            ),
        )
        return 0usize
    }
    if i >= MAX_MOVE_PARAMS {
        push_diag_e(
            self,
            span,
            E_MOVE_REF_PARAM,
            $"`move` is supported on the first {MAX_MOVE_PARAMS} parameters only",
        )
        return 0usize
    }
    return move_bit(i)
}

fn resolve_generic_bind(self: &Checker, g: &GenericBindType) Ty {
    // `$T` introduces a type parameter. Each binding becomes a fresh variable scoped to the
    // function's signature; subsequent `T` references look it up from the env. During an
    // instantiation's re-check the name is pre-bound to a concrete type, so the lookup path returns
    // that instead of minting a var.
    let existing = self.env.lookup(g.name)
    if existing.is_some() {
        return self.engine.specialize(&existing.unwrap().scheme)
    }
    refuse_self_name(self, g.name, g.span)
    let fresh = self.engine.fresh_var()
    let vid = ty_node(self, fresh) match { NVar(v) => v.id, _ => 0u32 }
    self.sig_tps.push(SigTypeParam { name = g.name, ty = fresh, decl = self.node_of(g.span) })
    self.tp_names.set(vid, g.name)
    self.env.bind(
        g.name,
        Binding {
            scheme = mono(fresh),
            decl = self.node_of(g.span),
            is_const = true,
            is_type_param = true,
        },
    )
    return fresh
}

// ─────────────────────────────────────────────────────────────────────
// Diagnostic helpers - small, lift to reporter when complexity grows.
// ─────────────────────────────────────────────────────────────────────

// Scoped mutability: installs the target platform's compile-time context (cross-target builds).
// Fields are writable only in the defining file. Template expansion evaluates each invocation in
// its origin module's scope.
pub fn set_current_module(self: &Checker, module_path: String) {
    self.current_module = Some(module_path)
}

pub fn set_comptime_ctx(self: &Checker, ctx: ComptimeCtx) {
    self.comptime = ctx
}

// Turn `test {}` body checking on or off for every demand run through this checker.
pub fn set_check_tests(self: &Checker, on: bool) {
    self.check_tests = on
}

// Install `flang.toml`'s `[imports].global` for this check. `origin` is parallel to the module list
// `check_all` will be given: true for a project file, false for stdlib/dependency modules. Copies
// both, so the caller's lists need not outlive the call.
pub fn set_project_globals(self: &Checker, names: &List(OwnedString), origin: &List(bool)) {
    for &n in names {
        self.project_globals.push(from_view(n.view))
    }
    for i in 0..origin.len {
        self.project_origin.push(origin[i])
    }
}

pub fn push_diag_e(self: &Checker, span: SourceSpan, code: String, message: move OwnedString) {
    let empty_hint: OwnedString
    self.diagnostics.push(Diagnostic {
        severity = Severity.Error,
        code = code,
        message = move message,
        hint = move empty_hint,
        span = span,
    })
}

// Warning-severity counterpart. Warnings render like errors but do not fail the build
// (`driver.count_errors` filters on severity).
pub fn push_diag_w(self: &Checker, span: SourceSpan, code: String, message: move OwnedString) {
    let empty_hint: OwnedString
    self.diagnostics.push(Diagnostic {
        severity = Severity.Warning,
        code = code,
        message = move message,
        hint = move empty_hint,
        span = span,
    })
}

// Info-severity counterpart: a note on source that is valid as written.
pub fn push_diag_i(self: &Checker, span: SourceSpan, code: String, message: move OwnedString) {
    let empty_hint: OwnedString
    self.diagnostics.push(Diagnostic {
        severity = Severity.Info,
        code = code,
        message = move message,
        hint = move empty_hint,
        span = span,
    })
}

// Translate a unify outcome into a diagnostic anchored at `span`. A `Unified` outcome produces
// nothing; every mismatch produces one diagnostic on the checker's list.
fn report_unify(self: &Checker, outcome: &UnifyOutcome, code: String, span: SourceSpan) {
    let ctx = report_ctx(code, span, Some(&self.nominals))
    report(outcome, &ctx, &self.engine.interner, &self.diagnostics)
}

pub fn current_visibility(self: &Checker) Visibility {
    return self.current_module match {
        Some(m) => visibility(Some(m), base_visible_set(self, m))
        None => open()
    }
}

// The modules visible from `m`, as a fresh caller-owned set.
fn base_visible_set(self: &Checker, m: String) Set(String) {
    let fresh: Set(String) = set()
    self.visible_by_module.get_ref(m) match {
        Some(src) => copy_set_into(&fresh, src)
        None => {
            let _new = fresh.add(m)
        }
    }
    return fresh
}

// Visibility for FUNCTION lookups. A template body under instantiation also dispatches to overloads
// its caller chain imports (`hash()` for `Dict`) - deliberately caller-dependent: the FIRST
// instantiation of a signature fixes the winning targets for everyone. The union applies to
// functions ONLY: widening nominal/variant lookups the same way lets a caller's `Decl.Type(...)`
// variant capture the template's `Type(T)` RTTI expression (found the hard way in
// `std.allocator.box` instantiated from the projector).
fn fn_visibility(self: &Checker) Visibility {
    if self.spec_callers.len == 0 {
        return current_visibility(self)
    }
    return self.current_module match {
        Some(m) => {
            // Built locally before wrapping - growing a set through a returned struct's field is
            // the two-field-hop hazard.
            let fresh = base_visible_set(self, m)
            for c in self.spec_callers {
                fresh.add(c)
                self.visible_by_module.get_ref(c) match {
                    Some(src) => copy_set_into(&fresh, src)
                    None => {}
                }
            }
            visibility(Some(m), fresh)
        }
        None => open()
    }
}

// ponytail: rebuilds the returned set per lookup; cache on the checker if profiling flags it. The
// reads stay O(visible-module-count), which is small.
fn copy_set_into(dst: &Set(String), src: &Set(String)) {
    let it = src.iter()
    loop {
        let n = it.next()
        if n.is_none() {
            break
        }
        dst.add(n.unwrap())
    }
}

// Build `visible_by_module` from the modules' import declarations: each module sees itself, its
// direct imports, the `pub import` transitive closure reachable through them, and the auto-imported
// core prelude.
fn build_visibility(self: &Checker, modules: &List(Module), paths: &List(String)) {
    let n = modules.len

    // Per-module edge lists (views into `paths`): all imports, and the `pub import` subset that
    // re-exports transitively.
    let imports: List(List(String)) = list(0)
    let reexports: List(List(String)) = list(0)
    for i in 0..n {
        let imps: List(String) = list(0)
        let reexps: List(String) = list(0)
        collect_edges(&modules[i], paths, &imps, &reexps)
        if paths[i] != "core.prelude" {
            let pre = find_fqn(paths, "core.prelude")
            if pre.is_some() {
                let pv = pre.unwrap()
                if !contains_view(&imps, pv) {
                    imps.push(pv)
                }
            }
        }
        // Project-level globals are implicit PRIVATE imports (they widen the file's own scope, they
        // do not re-export), and only project files get them. Same rule as the reference compiler
        // (Compiler.cs).
        if i < self.project_origin.len and self.project_origin[i] {
            for &g in self.project_globals {
                let gv = find_fqn(paths, g.view)
                if gv.is_some() {
                    let v = gv.unwrap()
                    if !contains_view(&imps, v) {
                        imps.push(v)
                    }
                }
            }
        }
        imports.push(imps)
        reexports.push(reexps)
    }

    for i in 0..n {
        let vis: Set(String) = set()
        compute_visible(i, paths, &imports, &reexports, &vis)
        self.visible_by_module.set(paths[i], vis)
    }

    imports.deinit()
    reexports.deinit()
}

// Record module `m`'s imports as views into `paths`. An import whose dotted path names no loaded
// module is silently dropped here; the unresolved-import diagnostic is the loader's job.
fn collect_edges(m: &Module, paths: &List(String), imps: &List(String), reexps: &List(String)) {
    for &d in m.decls {
        d.* match {
            Import(id) => {
                let dotted = dot_join(id.path)
                let fv = find_fqn(paths, dotted.view)
                dotted.deinit()
                if fv.is_some() {
                    let v = fv.unwrap()
                    if !contains_view(imps, v) {
                        imps.push(v)
                    }
                    if id.is_pub {
                        if !contains_view(reexps, v) {
                            reexps.push(v)
                        }
                    }
                }
            }
            _ => {}
        }
    }
}

// `{idx} ∪ imports(idx)` then a BFS that follows only `pub import` edges,
// per the spec's non-transitive-import / transitive-re-export rule.
fn compute_visible(
    idx: usize,
    paths: &List(String),
    imports: &List(List(String)),
    reexports: &List(List(String)),
    out: &Set(String),
) {
    out.add(paths[idx])
    let work: List(String) = list(0)
    for im in imports[idx] {
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
            for rv in reexports[ni.unwrap()] {
                if !out.contains(rv) {
                    out.add(rv)
                    work.push(rv)
                }
            }
        }
    }
    work.deinit()
}

pub fn dot_join(segs: String[]) OwnedString {
    let sb = string_builder(0)
    defer sb.deinit()
    for i in 0..segs.len {
        if i > 0 {
            sb.append('.')
        }
        sb.append(segs[i])
    }
    return sb.to_string()
}

// ponytail: linear scans over `paths`; index by FQN if module counts grow.
fn find_fqn(paths: &List(String), name: String) String? {
    for i in 0..paths.len {
        if paths[i] == name {
            return Some(paths[i])
        }
    }
    return null
}

fn find_index(paths: &List(String), name: String) usize? {
    for i in 0..paths.len {
        if paths[i] == name {
            return Some(i)
        }
    }
    return null
}

fn contains_view(list: &List(String), v: String) bool {
    for i in 0..list.len {
        if list[i] == v {
            return true
        }
    }
    return false
}

// ─────────────────────────────────────────────────────────────────────
// Phase 1 - collect nominal types
//
// First pass: register every struct/enum/alias by FQN with a placeholder definition (empty
// fields/variants). Second pass: resolve each declaration's fields/variants now that every name in
// the module is known.
// ─────────────────────────────────────────────────────────────────────

// Register one module's type *names* (struct/enum placeholders). Bodies are resolved in a separate
// pass - see `resolve_nominal_bodies` - so a field or variant payload can reference a type declared
// in any module, in any order.
pub fn collect_nominal_names(self: &Checker, module: &Module, module_path: String) {
    self.current_module = Some(module_path)
    for &decl in module.decls {
        collect_one_name(self, decl, module_path)
    }
}

// Resolve one module's type bodies (struct fields, enum payloads). Runs only after every module's
// names are registered, so cross-module references in a body resolve regardless of module order.
pub fn resolve_nominal_bodies(self: &Checker, module: &Module, module_path: String) {
    self.current_module = Some(module_path)
    for &decl in module.decls {
        resolve_one_body(self, decl, module_path)
    }
}

fn collect_one_name(self: &Checker, decl: &Decl, module_path: String) {
    decl.* match {
        Type(td) => {
            refuse_self_name(self, td.name, td.span)
            let fqn_owned = $"{module_path}.{td.name}"
            if self.nominals.contains(fqn_owned.view) or self.aliases.contains(fqn_owned.view) {
                push_diag_e(
                    self,
                    td.span,
                    E_DUP_TYPE_DECL,
                    $"duplicate type declaration `{td.name}`",
                )
                fqn_owned.deinit()
                return
            }
            // Decide nominal vs alias by inspecting the body. The OwnedString is consumed by
            // whichever registry takes it: the nominal registry for struct/enum, the alias registry
            // for an alias body (stored unresolved for lazy expansion at use).
            let kind = nominal_kind_of(td.body)
            kind match {
                NkStruct => note_bound_text(
                    self,
                    register_struct_placeholder(self, &td, fqn_owned),
                    td.body,
                )
                NkEnum => note_bound_text(
                    self,
                    register_enum_placeholder(self, &td, fqn_owned),
                    td.body,
                )
                NkAlias => {
                    td.body match {
                        Contract(c) => self.self_decls.set(node_id_of(c.span), td.span)
                        _ => {}
                    }
                    register_alias(self, fqn_owned, td.body)
                }
            }
        }
        _ => {}
    }
}

fn resolve_one_body(self: &Checker, decl: &Decl, module_path: String) {
    decl.* match {
        Type(td) => {
            let kind = nominal_kind_of(td.body)
            kind match {
                NkStruct => resolve_struct_body(self, &td, module_path)
                NkEnum => resolve_enum_body(self, &td, module_path)
                NkAlias => {
                    if is_contract_body(td.body) {
                        validate_contract_decl(self, &td)
                    }
                }
            }
        }
        _ => {}
    }
}

type Nk = enum {
    NkStruct
    NkEnum
    NkAlias
}

fn nominal_kind_of(body: &TypeExpr) Nk {
    return body.* match {
        AnonStruct(_) => Nk.NkStruct
        AnonEnum(_) => Nk.NkEnum
        _ => Nk.NkAlias
    }
}

// Records how `id`'s parameter bounds spell, and whether that differs from the last collection's.
fn note_bound_text(self: &Checker, id: NominalId, body: &TypeExpr) {
    const generics = body.* match {
        AnonStruct(a) => a.generics
        AnonEnum(e) => e.generics
        _ => return
    }
    let sb = string_builder(32)
    let spelled = true
    for &g in generics {
        if g.bound.is_none() {
            continue
        }
        sb.append(g.name)
        sb.append(":")
        spelled = render_alias_body(g.bound.unwrap(), &sb) and spelled
        sb.append(";")
    }
    const old = self.bound_texts.remove(id)
    const same = spelled and old match {
        Some(t) => t.view == sb.as_view()
        None => sb.len == 0
    }
    if !same {
        self.bounds_changed = true
    }
    old match {
        Some(t) => t.deinit()
        None => {}
    }
    if sb.len == 0 {
        sb.deinit()
        return
    }
    self.bound_texts.set(id, sb.to_string())
}

fn register_struct_placeholder(self: &Checker, td: &TypeDecl, fqn: move OwnedString) NominalId {
    let empty_params: List(VarId) = list(0)
    let empty_fields: List(Field) = list(0)
    // `fqn` field is a placeholder - `register` overwrites it with the stable view it owns. The
    // OwnedString is transferred to the registry.
    let sd = StructDef {
        fqn = "",
        module = self.current_module.unwrap(),
        is_pub = td.is_pub,
        type_params = move empty_params,
        assoc_params = list(0),
        fields = move empty_fields,
        decl_span = td.span,
        deprecation = deprecation_of(td.directives),
        // `#simd` over-aligns the type; `#foreign` locks its layout to the C ABI (spec 2.4 / 10).
        // Dropping these left every struct on the `Repr.Auto` path, so a `#foreign struct` was
        // reordered by descending alignment like any other - exactly the layout the marker exists
        // to opt out of.
        is_simd = is_simd_directive(td.directives),
        is_foreign = is_foreign_directive(td.directives),
    }
    return register_collected(self, NominalDef.NomStruct(move sd), fqn)
}

fn register_enum_placeholder(self: &Checker, td: &TypeDecl, fqn: move OwnedString) NominalId {
    let empty_params: List(VarId) = list(0)
    let empty_variants: List(VariantDef) = list(0)
    let ed = EnumDef {
        fqn = "",
        module = self.current_module.unwrap(),
        is_pub = td.is_pub,
        type_params = move empty_params,
        assoc_params = list(0),
        variants = move empty_variants,
        tag_values = null,
        decl_span = td.span,
        deprecation = deprecation_of(td.directives),
    }
    return register_collected(self, NominalDef.NomEnum(move ed), fqn)
}

fn resolve_struct_body(self: &Checker, td: &TypeDecl, module_path: String) {
    let fqn_owned = $"{module_path}.{td.name}"
    let id_opt = self.nominals.lookup_fqn(fqn_owned.view)
    fqn_owned.deinit()
    if id_opt.is_none() {
        return
    }
    let id = id_opt.unwrap()

    let anon_opt = td.body match {
        AnonStruct(a) => Some(a)
        _ => null
    }
    if anon_opt.is_none() {
        return
    }
    let anon = anon_opt.unwrap()

    // Bind generics into a fresh scope so field type-exprs can see them.
    self.env.push_scope()
    let type_params: List(VarId) = list(anon.generics.len)
    let self_args: List(Ty) = list(anon.generics.len)
    for &gp in anon.generics {
        refuse_self_name(self, gp.name, gp.span)
        let fresh = self.engine.fresh_var()
        let id = ty_node(self, fresh) match { NVar(v) => v.id, _ => 0u32 }
        type_params.push(id)
        self_args.push(fresh)
        self.tp_names.set(id, gp.name)
        self.env.bind(
            gp.name,
            Binding {
                scheme = mono(fresh),
                decl = self.node_of(gp.span),
                is_const = true,
                is_type_param = true,
            },
        )
    }
    bind_type_name(self, SELF_NAME, mk_nominal(self, id, self_args), td.span)
    lower_type_params(self, id, anon.generics)

    let fields: List(Field) = list(anon.fields.len)
    for &f in anon.fields {
        let ty = resolve_type_expr(self, f.type_expr)
        // A field name twice would make every later lookup ambiguous and silently pick the first -
        // reject at the declaration.
        if field_named(&fields, f.name) {
            push_diag_e(
                self,
                f.span,
                E_DUP_FIELD,
                $"duplicate field `{f.name}` in struct `{td.name}`",
            )
            continue
        }
        fields.push(Field {
            name = f.name,
            ty = self.engine.zonk(ty),
            decl_span = f.span,
            owned = f.owned,
        })
    }
    self.env.pop_scope()
    let assoc_params: List(VarId) = list(0)
    for &f in fields {
        collect_assoc_vars(self, f.ty, &assoc_params)
    }

    // Re-write the registry entry with the resolved body, freeing whatever body it held - the empty
    // placeholder lists, or a carried body being resolved over.
    let existing = self.nominals.get(id)
    existing.* match {
        NomStruct(sd) => {
            let updated = StructDef {
                fqn = sd.fqn,
                module = sd.module,
                is_pub = sd.is_pub,
                type_params = move type_params,
                assoc_params = move assoc_params,
                fields = move fields,
                decl_span = sd.decl_span,
                deprecation = sd.deprecation,
                is_simd = sd.is_simd,
                is_foreign = sd.is_foreign,
            }
            self.nominals.replace_body(id, NominalDef.NomStruct(move updated))
        }
        _ => {}
    }
    check_recursive_nominal(self, id, td.name, td.span)
}

// E2035: a struct or enum that contains itself BY VALUE has no finite size. References break the
// cycle (`&Node` is pointer-sized), which is how linked structures are written. The walk is
// transitive so mutual recursion is caught too, and `seen` keeps it terminating.
fn check_recursive_nominal(self: &Checker, id: NominalId, name: String, span: SourceSpan) {
    const cut = cut_back_edges(self, id)
    if cut.is_none() {
        return
    }
    const noun = if cut.unwrap().1 { "variant" } else { "field" }
    push_diag_e(
        self,
        span,
        E_RECURSIVE_TYPE,
        $"recursive type `{name}` has infinite size - {noun} `{cut.unwrap().0}` reaches back to it; break the cycle with a reference",
    )
}

// Poison every by-value member that reaches back to `id`, and report whether any did.
//
// Reporting alone would leave a definition of infinite size in the registry for every pass that
// runs after, so each one would need a cycle guard of its own to walk fields at all. Cutting the
// edge makes the definition finite in the data instead: `Error` unifies with anything and cascades
// no diagnostic, so the rest of the type still checks and the member that closed the loop is the
// only one that stops carrying a type. Mutual recursion terminates the same way - cutting `A`'s
// back-edge breaks the loop, and `B` cuts its own when its turn comes.
//
// Returns the first member cut and whether it is an enum variant rather than a struct field, so the
// diagnostic can name what closed the loop.
fn cut_back_edges(self: &Checker, id: NominalId) (String, bool)? {
    let seen: Set(NominalId) = set()
    defer seen.deinit()
    let hit: (String, bool)? = null
    let def = self.nominals.get(id)
    def.* match {
        NomStruct(sd) => {
            for i in 0..sd.fields.len {
                seen.clear()
                if ty_contains_nominal(self, sd.fields[i].ty, id, &seen) {
                    if hit.is_none() {
                        hit = Some((sd.fields[i].name, false))
                    }
                    sd.fields[i] = Field {
                        name = sd.fields[i].name,
                        ty = TY_ERROR,
                        decl_span = sd.fields[i].decl_span,
                        owned = sd.fields[i].owned,
                    }
                }
            }
        }
        NomEnum(ed) => {
            for vi in 0..ed.variants.len {
                for pi in 0..ed.variants[vi].payloads.len {
                    seen.clear()
                    if ty_contains_nominal(self, ed.variants[vi].payloads[pi], id, &seen) {
                        if hit.is_none() {
                            hit = Some((ed.variants[vi].name, true))
                        }
                        ed.variants[vi].payloads[pi] = TY_ERROR
                    }
                }
            }
        }
    }
    return hit
}

// Whether `target` is reachable from `current`'s by-value members.
fn nominal_contains(
    self: &Checker,
    current: NominalId,
    target: NominalId,
    seen: &Set(NominalId),
) bool {
    if seen.contains(current) {
        return false
    }
    seen.add(current)
    let def = self.nominals.get(current)
    let hit = false
    def.* match {
        NomStruct(sd) => {
            for i in 0..sd.fields.len {
                if !hit and ty_contains_nominal(self, sd.fields[i].ty, target, seen) {
                    hit = true
                }
            }
        }
        NomEnum(ed) => {
            for i in 0..ed.variants.len {
                let vd = &ed.variants[i]
                for k in 0..vd.payloads.len {
                    if !hit and ty_contains_nominal(self, vd.payloads[k], target, seen) {
                        hit = true
                    }
                }
            }
        }
    }
    return hit
}

// A `Ref` is where the walk stops - that is the whole point of the rule.
fn ty_contains_nominal(self: &Checker, t: Ty, target: NominalId, seen: &Set(NominalId)) bool {
    return ty_node(self, t) match {
        NNominal(nn) => {
            if nn.id == target {
                return true
            }
            // NOT the type arguments: `List(JsonValue)` is a fixed-size handle whose elements live
            // behind `ptr: &T`, and the walk into `List`'s own fields stops at that reference. The
            // cost is an under-approximation - a generic wrapper that stores its parameter BY VALUE
            // (`Wrapper(T) = struct { v: T }`) hides a cycle from this check, because the walk sees
            // the unsubstituted `T`. Substituting per instantiation belongs with the interning work
            // docs/self-host.md tracks.
            nominal_contains(self, nn.id, target, seen)
        }
        NArray(a) => ty_contains_nominal(self, a.elem, target, seen)
        NTuple(span) => span_contains_nominal(self, span, target, seen)
        _ => false
    }
}

fn span_contains_nominal(
    self: &Checker,
    span: ChildSpan,
    target: NominalId,
    seen: &Set(NominalId),
) bool {
    for i in 0..span.len {
        if ty_contains_nominal(self, self.engine.interner.child_at(span, i), target, seen) {
            return true
        }
    }
    return false
}

// Auto-deref: the value behind every reference hop. `(&&Point)` and `Point` look the same to a
// field lookup, a variant pattern, a match scrutinee and a scoped-mutability check, so they all
// start here.
fn peel_refs(self: &Checker, ty: Ty) Ty {
    let peeled = self.engine.resolve(ty)
    loop {
        let inner = ty_node(self, peeled) match {
            NRef(i) => Some(self.engine.resolve(i))
            _ => null
        }
        if inner.is_none() {
            break
        }
        peeled = inner.unwrap()
    }
    return peeled
}

fn field_named(fields: &List(Field), name: String) bool {
    for i in 0..fields.len {
        if fields[i].name == name {
            return true
        }
    }
    return false
}

fn variant_named(variants: &List(VariantDef), name: String) bool {
    for i in 0..variants.len {
        if variants[i].name == name {
            return true
        }
    }
    return false
}

// A signed compile-time integer written as a literal, optionally negated (`Less = -1`). Null for
// anything else - the tag check simply skips it.
fn const_int_of(self: &Checker, e: &Expr) i64? {
    let lit = e.* match {
        Lit(l) => Some(l)
        _ => null
    }
    if lit.is_some() {
        return lit.unwrap().value match {
            Int(i) => Some(parse_i64_text(i.text))
            _ => null
        }
    }
    let un = e.* match {
        Unary(u) => Some(u)
        _ => null
    }
    if un.is_none() {
        return null
    }
    let u = un.unwrap()
    let is_neg = u.op match { Neg => true, _ => false }
    if !is_neg {
        return null
    }
    let inner = const_int_of(self, u.operand)
    if inner.is_none() {
        return null
    }
    let n = inner.unwrap()
    return Some(0i64 - n)
}

// The magnitude parser handles decimal, hex, binary and octal; enum tags are written in any of
// them.
fn parse_i64_text(text: String) i64 {
    return parse_int_magnitude(text) match {
        Some(n) => n as i64
        None => 0i64
    }
}

fn resolve_enum_body(self: &Checker, td: &TypeDecl, module_path: String) {
    let fqn_owned = $"{module_path}.{td.name}"
    let id_opt = self.nominals.lookup_fqn(fqn_owned.view)
    fqn_owned.deinit()
    if id_opt.is_none() {
        return
    }
    let id = id_opt.unwrap()

    let anon_opt = td.body match {
        AnonEnum(a) => Some(a)
        _ => null
    }
    if anon_opt.is_none() {
        return
    }
    let anon = anon_opt.unwrap()

    self.env.push_scope()
    let type_params: List(VarId) = list(anon.generics.len)
    let self_args: List(Ty) = list(anon.generics.len)
    for &gp in anon.generics {
        refuse_self_name(self, gp.name, gp.span)
        let fresh = self.engine.fresh_var()
        let vid = ty_node(self, fresh) match { NVar(v) => v.id, _ => 0u32 }
        type_params.push(vid)
        self_args.push(fresh)
        self.tp_names.set(vid, gp.name)
        self.env.bind(
            gp.name,
            Binding {
                scheme = mono(fresh),
                decl = self.node_of(gp.span),
                is_const = true,
                is_type_param = true,
            },
        )
    }
    bind_type_name(self, SELF_NAME, mk_nominal(self, id, self_args), td.span)
    lower_type_params(self, id, anon.generics)

    let variants: List(VariantDef) = list(anon.variants.len)
    // Naked-enum tag assignment mirrors C: an explicit `= N` sets the counter, an implicit variant
    // takes the next value. Two variants landing on the same tag - explicitly or through the
    // counter - make
    // the enum's tag→variant mapping ambiguous (E2048).
    let tags: List(i64) = list(anon.variants.len)
    defer tags.deinit()
    // Variant name -> wire tag, kept only when the enum spells its tags out; a standard enum's tag
    // is its declaration index and needs no table.
    let tag_by_name: Dict(String, i64) = dict()
    let next_tag = 0i64
    let has_explicit_tag = false
    let has_payload = false
    for &v in anon.variants {
        let payloads: List(Ty) = list(v.payloads.len)
        for &p in v.payloads {
            payloads.push(self.engine.zonk(resolve_type_expr(self, p)))
        }
        if v.payloads.len > 0 {
            has_payload = true
        }
        v.explicit_tag match {
            Some(e) => {
                has_explicit_tag = true
                let n = const_int_of(self, e)
                if n.is_some() {
                    next_tag = n.unwrap()
                }
            }
            None => {}
        }
        if tags.contains(next_tag) {
            push_diag_e(
                self,
                v.span,
                E_DUP_TAG,
                $"duplicate tag value {next_tag} for variant `{v.name}` in enum `{td.name}`",
            )
        }
        tags.push(next_tag)
        tag_by_name.set(v.name, next_tag)
        next_tag = next_tag + 1i64
        if variant_named(&variants, v.name) {
            push_diag_e(
                self,
                v.span,
                E_DUP_VARIANT,
                $"duplicate variant `{v.name}` in enum `{td.name}`",
            )
            payloads.deinit()
            continue
        }
        variants.push(VariantDef { name = v.name, payloads = move payloads, decl_span = v.span })
    }
    let tag_values: Dict(String, i64)? = null
    if has_explicit_tag {
        install(&tag_values, Some(move tag_by_name))
    } else {
        tag_by_name.deinit()
    }
    self.env.pop_scope()
    let assoc_params: List(VarId) = list(0)
    for &v in variants {
        for p in v.payloads {
            collect_assoc_vars(self, p, &assoc_params)
        }
    }

    let existing = self.nominals.get(id)
    existing.* match {
        NomEnum(ed) => {
            let updated = EnumDef {
                fqn = ed.fqn,
                module = ed.module,
                is_pub = ed.is_pub,
                type_params = move type_params,
                assoc_params = move assoc_params,
                variants = move variants,
                tag_values = move tag_values,
                decl_span = ed.decl_span,
                deprecation = ed.deprecation,
            }
            self.nominals.replace_body(id, NominalDef.NomEnum(move updated))
        }
        _ => {}
    }
    check_recursive_nominal(self, id, td.name, td.span)
    // E2047: a NAKED enum - one that assigns integer tags - is a plain C-style enumeration; a
    // payload would have nowhere to live.
    if has_explicit_tag and has_payload {
        push_diag_e(
            self,
            td.span,
            E_NAKED_ENUM_PAYLOAD,
            $"enum `{td.name}` assigns explicit tag values, so no variant may carry a payload",
        )
    }
}

// ─────────────────────────────────────────────────────────────────────
// Phase 2 - collect function signatures
//
// Every `pub fn` and `fn` is registered with its polymorphic scheme before any body is checked.
// Forward references between functions in the same module just work; cross-module references depend
// on import visibility (out of scope for the first slice - visibility is "current module only").
// ─────────────────────────────────────────────────────────────────────

pub fn collect_signatures(self: &Checker, module: &Module, module_path: String) {
    self.current_module = Some(module_path)
    self.engine.set_nominal_registry(&self.nominals)

    for &decl in module.decls {
        collect_one_signature(self, decl)
    }
}

fn collect_one_signature(self: &Checker, decl: &Decl) {
    decl.* match {
        Function(fd) => register_function_sig(self, &fd)
        Const(cd) => register_constant(self, &cd)
        _ => {}
    }
}

// A module-level constant registers its declared type in the signature pass; without an annotation
// it gets a fresh variable the body pass binds from the initializer. Uses in any module unify
// against the same entry, so cross-module reads work regardless of check order. Whether the current
// module already registered `name` with a structurally identical signature. Only same-module
// collisions count: two modules may each declare `deinit(&Foo)` for their own `Foo`.
fn duplicate_overload(self: &Checker, name: String, sig: &Scheme) bool {
    let vis = current_visibility(self)
    defer vis.deinit()
    let found = self.functions.lookup(name, &vis) match {
        FnLookFound(c) => Some(move c)
        _ => null
    }
    if found.is_none() {
        return false
    }
    let cands = found.unwrap()
    defer cands.deinit()
    let here = self.current_module.unwrap_or("")
    for c in cands {
        let same_module = c.module match {
            Some(m) => m == here
            None => false
        }
        if same_module and c.signature.body == sig.body {
            return true
        }
    }
    return false
}

fn register_constant(self: &Checker, cd: &ConstDecl) {
    let ty = cd.type_annotation match {
        Some(t) => resolve_type_expr(self, t)
        None => self.engine.fresh_var()
    }
    let fqn = $"{self.current_module.unwrap()}.{cd.name}"
    // A second module-level constant under the same name would silently overwrite the first (E2005;
    // the local same-scope case is only a warning - see `check_let`).
    if self.constants.contains(fqn.view) {
        push_diag_e(self, cd.span, E_DUP_TYPE_DECL, $"global `{cd.name}` is already declared")
        fqn.deinit()
        return
    }
    self.constants.register(fqn, ty)
}

fn register_context_fields(self: &Checker, module: &Module, module_path: String) {
    self.current_module = Some(module_path)
    for &decl in module.decls {
        decl.* match {
            Context(cd) => register_context_field(self, &cd)
            _ => {}
        }
    }
}

// A `context` declaration registers its declared type (RFC-038). The type has to be copyable: the
// language copies a context on every `let c = context`, capture and rebind.
fn register_context_field(self: &Checker, cd: &ContextDecl) {
    const ty = resolve_type_expr(self, cd.type_annotation)
    let fqn = $"{self.current_module.unwrap()}.{cd.name}"
    if self.ctx_fields.contains(fqn.view) {
        push_diag_e(
            self,
            cd.name_span,
            E_DUP_TYPE_DECL,
            $"context field `{cd.name}` is already declared",
        )
        fqn.deinit()
        return
    }
    if ty != TY_ERROR and !ty_copyable(self, ty) {
        let sb = string_builder(64)
        defer sb.deinit()
        sb.append($"context field `{cd.name}` must have a copyable type")
        append_copy_blame(self, ty, &sb)
        push_diag_e(
            self,
            type_expr_span(cd.type_annotation),
            E_CONTEXT_NOT_COPYABLE,
            sb.to_string(),
        )
    }
    self.ctx_fields.register(
        fqn,
        CtxField { ty = ty, is_pub = cd.is_pub, name = cd.name, span = cd.span },
    )
}

fn register_function_sig(self: &Checker, fd: &FunctionDecl) {
    self.sig_tps.clear()
    self.sig_implied.clear()
    self.sig_declared.clear()
    self.proj_pending.clear()
    self.sig_refs.clear()
    self.sig_sugar.clear()
    self.sig_open = true
    self.sig_params_open = true
    self.env.push_scope()
    self.engine.enter_level()

    let params: List(Ty) = list(fd.params.len)
    let moves = 0usize
    for &p in fd.params {
        self.sugar_ok = true
        self.sugar_param = p.name
        const pt = param_ty(self, p)
        self.sugar_ok = false
        check_slot_param(self, p)
        moves = moves | move_bit_of(self, params.len, p.is_move, pt, p.span)
        // A default value is checked against its parameter HERE, at the declaration, so the
        // diagnostic names the parameter (E2070) rather than surfacing at some unrelated call site.
        p.default_value match {
            Some(dv) => {
                const dt = check_expr(self, dv)
                const o = self.engine.unify(dt, pt)
                report_unify(self, &o, E_DEFAULT_PARAM_TYPE, expr_span(dv))
            }
            None => {}
        }
        params.push(pt)
    }
    self.sig_params_open = false
    prebind_bound_names(self, fd)
    let ret = fd.return_type match {
        Some(rt) => resolve_type_expr(self, rt)
        None => TY_VOID
    }
    // What the signature's types imply comes first: a type's own bounds solve the associated types
    // a `where` entry may read (`F: fn(I.Item) bool` beside `self: &FilterIter($I, $F)`).
    let atoms: List(BoundAtom) = list(fd.bounds.len + self.sig_implied.len)
    lower_bounds(self, fd.bounds, &atoms)
    atoms.push_all(self.sig_sugar.as_slice())
    self.sig_open = false
    report_undeclared_projections(self)
    rerecord_sig_refs(self)
    let implied = replace(&self.sig_implied, list(0))
    implied.push_all(atoms.as_slice())
    atoms.deinit()
    atoms = move implied
    let fn_ty = self.engine.mk_func(params, ret, moves)

    self.engine.exit_level()
    let scheme = self.engine.generalize(fn_ty)
    quantify_atoms(self, &atoms, &scheme.quantified)
    settle_sig_tps(self, &scheme.quantified)
    self.env.pop_scope()

    // Trailing defaulted params and the variadic tail may be omitted at call sites.
    let required = fd.params.len
    loop {
        if required == 0 {
            break
        }
        let p = &fd.params[required - 1]
        if p.default_value.is_none() and !p.is_variadic {
            break
        }
        required = required - 1
    }

    let scheme_obj = FunctionScheme {
        name = fd.name,
        signature = move scheme,
        module = self.current_module,
        is_pub = fd.is_pub,
        is_foreign = is_foreign_directive(fd.directives),
        required_params = required,
        has_variadic = fd.params.len > 0 and fd.params[fd.params.len - 1].is_variadic,
        decl_span = fd.span,
        deprecation = deprecation_of(fd.directives),
        id = 0u32, // filled in by registry.register
        retired = false,
    }
    // E2103: two declarations of the same name in one module with the same parameter types. The
    // registry would keep both and overload resolution would pick by declaration order - silently
    // running one of them.
    let dup = duplicate_overload(self, fd.name, &scheme_obj.signature)
    if dup {
        push_diag_e(
            self,
            fd.span,
            E_DUP_SIGNATURE,
            $"duplicate definition of `{fd.name}` with the same parameter types",
        )
    }
    const quantified_count = scheme_obj.signature.quantified.len()
    let id = self.functions.register(scheme_obj)

    // M11: keep the declared parameter list around so call sites that omit trailing arguments can
    // materialize the default expressions (`materialize_default_args`); named-argument calls read
    // the same table for the parameter NAMES, so every function records, not just the defaulted
    // ones.
    let decl_params: List(FunctionParam) = list(fd.params.len)
    decl_params.push_all(fd.params)
    self.fn_decl_params.set(id, DeclParams { params = move decl_params })
    deprecation_of(fd.directives) match {
        Some(msg) => self.fn_deprecations.set(id, msg)
        None => {}
    }

    // A generic signature also records its instantiation template: the declaration plus the `$T`
    // bindings `resolve_generic_bind` just collected, in declaration order (M10). The list moves
    // in; the checker keeps a fresh one for the next signature. A reclaimed id's previous template
    // goes first - `Dict.set` would strand its list.
    self.templates.remove(id) match {
        Some(old) => old.tps.deinit()
        None => {}
    }
    self.fn_bounds.remove(id) match {
        Some(old) => old.deinit()
        None => {}
    }
    if atoms.len > 0 {
        self.fn_bounds.set(id, atoms)
    } else {
        atoms.deinit()
    }
    if quantified_count > 0 {
        // The template shares the declaration the module arena owns.
        self.templates.set(
            id,
            GenericTemplate {
                decl = fd,
                module = self.current_module.unwrap(),
                tps = replace(&self.sig_tps, list(0)),
            },
        )
    }
}

// ─────────────────────────────────────────────────────────────────────
// Phase 3 - check function bodies
//
// For each function with a body, push the function's frame, push a scope for its parameters, walk
// the block expression, and unify the body's type against the declared return.
//
// Body inference is in `checker_expr.f` / `checker_stmt.f`; this file only orchestrates.
// ─────────────────────────────────────────────────────────────────────

// Phase 2.5: pin every module-level constant's type from its initializer. An unannotated `const`
// only gets a fresh variable in the signature pass, so a function body checked BEFORE the
// initializer sees an open var - and an open var unifies with every candidate in an overload probe
// at equal cost, letting declaration order pick the winner. That is how `stdin.reader()` resolved
// to `reader(&BufferedReader)`: `stdin` was still unpinned when `main` was checked, and the
// mismatch surfaced later, blamed on the const's own declaration.
pub fn check_module_constants(self: &Checker, module: &Module, module_path: String) {
    self.current_module = Some(module_path)

    for &decl in module.decls {
        decl.* match {
            Const(cd) => check_constant_init(self, &cd)
            Context(cd) => check_context_default(self, &cd)
            _ => {}
        }
    }
}

// A context field's default fills the static root context, so it has to be a constant initializer
// (RFC-038).
fn check_context_default(self: &Checker, cd: &ContextDecl) {
    let fqn = $"{self.current_module.unwrap()}.{cd.name}"
    defer fqn.deinit()
    const v = check_expr(self, cd.value)
    const field = self.ctx_fields.get_fqn(fqn.view)
    if field.is_none() {
        return
    }
    unify_expected(self, v, field.unwrap().ty, E_TYPE_MISMATCH, expr_span(cd.value))
    if !is_const_init(self, cd.value) {
        push_diag_e(
            self,
            expr_span(cd.value),
            E_CONTEXT_DEFAULT,
            $"the default of context field `{cd.name}` must be a constant initializer: a literal, a function or variant name, the address of a module constant, or a struct literal of those",
        )
    }
}

// Whether `e` is a constant initializer: what lowering encodes into a static's bytes. A literal, a
// negated literal, a function name, a payload-less variant, the address of a module constant, a
// pointer cast of an address, or a struct literal whose every field is one.
fn is_const_init(self: &Checker, e: &Expr) bool {
    return e.* match {
        Lit(_) => true
        Unary(u) => u.op match {
            Neg => u.operand.* match { Lit(_) => true, _ => false }
            _ => false
        }
        Identifier(id) => self.results.resolved_targets.get(self.node_of(id.span)) match {
            Some(t) => t match {
                RtFunction(_) => true
                RtEnumVariant(_, _) => true
                _ => false
            }
            None => false
        }
        MemberAccess(ma) => self.results.resolved_targets.get(self.node_of(ma.span)) match {
            Some(t) => t match { RtEnumVariant(_, _) => true, _ => false }
            None => false
        }
        AddressOf(a) => a.operand.* match {
            Identifier(id) => self.results.resolved_targets.get(self.node_of(id.span)) match {
                Some(t) => t match { RtConst(_) => true, _ => false }
                None => false
            }
            _ => false
        }
        Cast(c) => c.operand.* match {
            AddressOf(_) => is_const_init(self, c.operand)
            _ => false
        }
        StructLit(sl) => {
            for &fi in sl.fields {
                const ok = fi.value match {
                    Some(v) => is_const_init(self, v)
                    None => false
                }
                if !ok {
                    return false
                }
            }
            true
        }
        _ => false
    }
}

pub fn check_module_bodies(self: &Checker, module: &Module, module_path: String) {
    self.current_module = Some(module_path)
    const tests = wants_test_bodies(self, module)

    for &decl in module.decls {
        check_one_decl(self, decl, tests)
    }
}

// Whether this module's `test {}` bodies are part of the demand. Both halves have to hold: the
// demand asked for tests, and the module is one of the project's own - a dependency's tests belong
// to a run launched from that dependency's directory.
fn wants_test_bodies(self: &Checker, module: &Module) bool {
    if !self.check_tests {
        return false
    }
    const i = module.span.file_id
    if i < 0 {
        return false
    }
    const idx = i as usize
    return idx < self.project_origin.len and self.project_origin[idx]
}

fn check_one_decl(self: &Checker, decl: &Decl, tests: bool) {
    decl.* match {
        Function(fd) => {
            // A generic template's body is validated per instantiation (M10), and once against
            // rigid type parameters for what cannot depend on them.
            if declares_generic(&fd) or template_id_of(self, &fd).is_some() {
                check_template_rigid(self, &fd)
            } else {
                check_function_body(self, &fd)
            }
        }
        Test(td) => {
            if tests {
                check_test_body(self, &td)
            }
        }
        // Consts were pinned in phase 2.5 (`check_module_constants`).
        _ => {}
    }
}

// A `test {}` block is a void body with no parameters and no name to return through. It gets a
// frame all the same, so a `return` inside one is checked against void rather than reaching for an
// enclosing function that does not exist.
fn check_test_body(self: &Checker, td: &TestDecl) {
    self.env.push_scope()
    self.engine.enter_level()

    let frame = FnFrame { name = td.label, return_ty = TY_VOID, decl_span = td.span }
    self.fn_stack.push(frame)

    const _body_ty = check_block(self, td.body)
    own_check_body(self, td.body, null, false)

    let _r = self.fn_stack.pop()
    self.engine.exit_level()
    self.env.pop_scope()
}

fn check_constant_init(self: &Checker, cd: &ConstDecl) {
    let fqn = $"{self.current_module.unwrap()}.{cd.name}"
    let reg = self.constants.get_fqn(fqn.view)
    // The decl node carries its own FQN as an RtConst target - lowering's const pre-pass reads it
    // to name the global (M11), so no module-path plumbing is needed lowering-side. Interned;
    // outlives the checker.
    let stable = self.results.add_synth_string(fqn)
    self.results.record_target(self.node_of(cd.span), ResolvedTarget.RtConst(stable))
    let v = check_expr(self, cd.value)
    unify_expected(self, v, reg.unwrap(), E_TYPE_MISMATCH, cd.span)
}

fn check_function_body(self: &Checker, fd: &FunctionDecl) {
    if fd.body.is_none() {
        return
    }
    let body = fd.body.unwrap()

    self.env.push_scope()
    self.engine.enter_level()

    // An instantiation's signature types were the call's to check: what they imply held there.
    const saved_apps = self.check_apps
    if self.spec_depth > 0 {
        self.check_apps = false
    }
    let params: List(Ty) = list(fd.params.len)
    for &p in fd.params {
        self.sugar_ok = true
        let ty = param_ty(self, p)
        self.sugar_ok = false
        // The parameter's type on its own node: a cursor on the signature resolves (hover).
        const p_node = self.node_of(p.span)
        self.results.record_type(p_node, ty)
        self.env.bind(
            p.name,
            Binding { scheme = mono(ty), decl = p_node, is_const = false, is_type_param = false },
        )
        params.push(ty)
    }
    let ret = fd.return_type match {
        Some(rt) => resolve_type_expr(self, rt)
        None => TY_VOID
    }
    self.check_apps = saved_apps

    let frame = FnFrame { name = fd.name, return_ty = ret, decl_span = fd.span }
    self.fn_stack.push(frame)

    let body_ty = check_block(self, body)
    // Only the implicit-return path is checked here: a block whose final expression is the
    // function's value. A block that ends in an explicit `return` yields Void and is covered by
    // `check_return`, so Void is skipped to avoid a spurious "expected T, got void". A void
    // function discards its trailing expression's value entirely.
    let ret_is_void = ret == TY_VOID
    if body_ty != TY_VOID and !ret_is_void {
        unify_expected(self, body_ty, ret, E_RETURN_MISMATCH, fd.span)
    }

    // E2049: a value-returning function whose body can fall off the end. `never` returns diverge by
    // definition, and a body whose last statement is an expression is the implicit-return form.
    let ret_is_never = ret == TY_NEVER
    if !ret_is_void and !ret_is_never and !block_returns(self, body) {
        push_diag_e(self, fd.span, E_MISSING_RETURN, $"function `{fd.name}` must return a value")
    }

    if !self.skip_ownership {
        own_check_body(self, body, Some(fd.params), !ret_is_void and !ret_is_never)
    }

    let _r = self.fn_stack.pop()
    self.engine.exit_level()
    self.env.pop_scope()
}

// Whether every path out of `block` produces the function's value: an explicit `return`, an
// `if`/`match` whose every arm does, or - the implicit-return form - a trailing expression / final
// expression statement. Mirrors the reference's `HasReturnOrImplicitReturn`.
fn block_returns(self: &Checker, block: &BlockExpr) bool {
    if block.trailing.is_some() {
        return true
    }
    if block.stmts.len == 0 {
        return false
    }
    for i in 0..block.stmts.len {
        if stmt_returns(self, &block.stmts[i]) {
            return true
        }
    }
    return block.stmts[block.stmts.len - 1] match {
        Expression(_) => true
        // A bare `loop` falls through only via `break`; a function that ends in one either returns
        // from inside or never returns at all. (The reference reaches the same verdict - its `loop`
        // is an expression statement, which its last-statement rule accepts.)
        Loop(_) => true
        _ => false
    }
}

fn stmt_returns(self: &Checker, stmt: &Stmt) bool {
    return stmt.* match {
        Return(_) => true
        Expression(es) => expr_returns(self, es.expr)
        IfDirective(ifd) => directive_branch_returns(self, &ifd)
        _ => false
    }
}

fn expr_returns(self: &Checker, e: &Expr) bool {
    return e.* match {
        Block(b) => block_returns(self, &b)
        If(ife) => if_returns(self, &ife)
        Match(m) => match_returns(self, &m)
        ContextBind(cb) => block_returns(self, cb.body)
        _ => false
    }
}

fn if_returns(self: &Checker, ife: &IfExpr) bool {
    if !block_returns(self, ife.then_branch) {
        return false
    }
    return ife.else_branch match {
        Block(b) => block_returns(self, b)
        If(nested) => if_returns(self, nested)
        NoElse => false
    }
}

fn match_returns(self: &Checker, m: &MatchExpr) bool {
    if m.arms.len == 0 {
        return false
    }
    for i in 0..m.arms.len {
        if !expr_returns(self, m.arms[i].body) {
            return false
        }
    }
    return true
}

// A `#if` diverges exactly when its ACTIVE branch does (the inactive one is not part of the
// program).
// The branch a statement-level `#if` takes here. A generic body is checked per specialization
// (`instantiate`), with its type parameters bound in `env`, so a condition over `type_info(T)`
// decides per instantiation; `checker_name` is what lets the evaluator see those bindings.
fn directive_outcome(self: &Checker, ifd: &IfDirectiveStmt) CtOutcome {
    const lookup: CtLookup = .{ ctx = self as &u8, resolve = no_lookup, name = checker_name }
    return eval_condition_with(&self.comptime, lookup, ifd.condition)
}

// A name in a `#if` condition: a type parameter in scope is the type bound to it, a non-generic
// nominal visible from the module is itself, and any other binding in scope is a value of its type.
// What is recorded on the identifier's node is what the name means in expression position - the
// reified `Type(T)` for a type, the value's type for a value - so lowering, which evaluates the
// same condition, reads it back from the result tables without resolving names of its own.
fn checker_name(raw: &u8, name: String, span: SourceSpan) CtValue? {
    const chk = raw as &Checker
    chk.env.lookup(name) match {
        Some(b) => {
            const ty = chk.engine.zonk(chk.engine.specialize(&b.scheme))
            if chk.engine.is_var(ty) and !chk.engine.is_rigid(ty) {
                return null
            }
            if b.is_type_param {
                return Some(directive_type(chk, ty, span))
            }
            chk.results.record_type(node_of(chk, span), ty)
            return Some(CtValue.Value(directive_info(chk, ty)))
        }
        None => {}
    }
    return directive_nominal(chk, name) match {
        Some(ty) => Some(directive_type(chk, ty, span))
        None => null
    }
}

fn directive_type(self: &Checker, ty: Ty, span: SourceSpan) CtValue {
    self.results.record_type(node_of(self, span), reified_type_of(self, ty))
    return CtValue.TypeInfo(directive_info(self, ty))
}

fn directive_info(self: &Checker, ty: Ty) CtTypeInfo {
    return ct_type_info_of_ty(&self.engine.interner, &self.nominals, ty, Some(&self.engine.rigid))
}

// A generic nominal has no type to offer without its arguments, and a bare name carries none.
fn directive_nominal(self: &Checker, name: String) Ty? {
    let vis = current_visibility(self)
    defer vis.deinit()
    const id = self.nominals.lookup(name, &vis) match {
        NomLookFound(i) => i
        _ => return null
    }
    const generic = self.nominals.get(id).* match {
        NomStruct(s) => s.type_params.len > 0
        NomEnum(e) => e.type_params.len > 0
    }
    if generic {
        return null
    }
    let none: List(Ty) = list(0)
    defer none.deinit()
    return Some(self.engine.interner.nominal_of(id, &none))
}

fn directive_branch_returns(self: &Checker, ifd: &IfDirectiveStmt) bool {
    directive_outcome(self, ifd) match {
        Active(active) => {
            const stmts = if active { ifd.then_stmts } else { ifd.else_stmts }
            for i in 0..stmts.len {
                if stmt_returns(self, &stmts[i]) {
                    return true
                }
            }
            return false
        }
        Invalid(_) => return false
    }
    return false
}

// ─────────────────────────────────────────────────────────────────────
// Phase 3.5 - generic specialization (M10)
//
// Every commit of a generic overload left a `PendingSpec` behind. Once the surrounding inference
// has settled, each pending pick either reuses an existing specialization (same template, same
// concrete signature) or instantiates one: the template body is re-checked - original AST, no clone
// - with its type params bound to the concrete arguments, recording into a private overlay of the
// result tables. The pick's node is then rewritten to cite the specialization, so lowering never
// sees a generic callee.
// ─────────────────────────────────────────────────────────────────────

// A chain of instantiations this deep is infinitely recursive polymorphism (each level must have a
// NEW concrete signature - plain self-recursion reuses its own key and never recurses here). The
// reference caps at 32 and skips silently; this reports.
const MAX_SPEC_DEPTH: usize = 64

// Drain the pending picks of the body scope that just finished. `process_pending` never appends to
// this list: picks recorded during a nested instantiation's body check land on that frame's own
// (swapped-in) list and drain there.
// Whether a pending can be instantiated now. The test is SHALLOW, and deliberately so (reference
// parity): only a type that IS a bare var blocks. A type argument nested inside a known constructor
// - `to_list(it: $I) List($T)`, `max(it: $I) $T?` - does NOT block, because instantiating runs the
// template body, and it is the body that derives `$T` from the iterator it drives. The settled
// signature is re-zonked and re-keyed at the end of `instantiate`, and once more program-wide in
// `zonk_specializations` for the nested instantiations that finished before their caller's body
// pinned the var.
//
// A bare var, by contrast, gives the body nothing to work from - that is the genuinely un-inferable
// call site (E2001).
fn pending_ready(self: &Checker, p: &PendingSpec) bool {
    for i in 0..p.inst_params.len {
        if self.engine.is_var(self.engine.zonk(p.inst_params[i])) {
            return false
        }
    }
    return !self.engine.is_var(self.engine.zonk(p.inst_ret))
}

// Drain the pending picks of the body scope that just finished, to a FIXPOINT. One pass is not
// enough: a pick's type arguments can be settled by a LATER pick's instantiation body -
// `to_list(it)`'s `$T` comes from the `next` that drives it, and `next`'s own instantiation is
// queued behind it. Each pass instantiates every ready pending and re-queues the rest (plus
// anything the instantiations enqueued); the loop stops when a whole pass resolves nothing new, and
// whatever is left is genuinely un-inferable - unless `report` is off: a first drain, run before
// the scope's parked member accesses and calls are settled, leaves what it could not place queued
// for the drain after them (a parked `x.double()` is what pins the lambda parameter `x` that an
// `apply(f, x)` pick is waiting on).
fn drain_pending_specs(self: &Checker, report: bool = true) {
    let queue = replace(&self.pending_specs, list(0))
    loop {
        let deferred: List(PendingSpec) = list(queue.len)
        let progressed = false
        for p in queue.drain() {
            if pending_ready(self, &p) {
                process_pending(self, &p)
                // A processed pick's collections are done; a deferred one keeps its storage into
                // the next pass, so the queue itself is never element-deinited.
                p.tp_binds.deinit()
                p.inst_params.deinit()
                progressed = true
            } else {
                deferred.push(p)
            }
        }
        // Picks the instantiations just made at THIS level join the queue.
        for q in self.pending_specs.drain() {
            deferred.push(q)
            progressed = true
        }
        self.pending_specs.clear()
        install(&queue, deferred)
        if !progressed {
            break
        }
        if queue.len == 0 {
            break
        }
    }
    for p in queue.drain() {
        if report {
            report_uninferable_spec(self, &p)
            p.tp_binds.deinit()
            p.inst_params.deinit()
        } else {
            self.pending_specs.push(p)
        }
    }
    queue.deinit()
}

// ─────────────────────────────────────────────────────────────────────
// Contracts (RFC-035)
//
// A `where` bound lowers once, at the signature, to a flat list of atoms over the signature's own
// type variables: `I: Iterator($T)` is one `Require` atom, `next(&I) T?`; `T: Key` is a `Copyable`
// plus one `Require` per member of `Hash` and `Eq`. A call substitutes its instantiation into each
// atom and asks whether it holds: a `Require` when the call it describes resolves, a `Callable`
// when the argument can be called with that shape. Overload probing drops a candidate whose atoms
// fail; the committed pick keeps what its atoms solved (`$T`, a lambda's parameter types); the
// specialization drain reports what still fails (E2134).
// ─────────────────────────────────────────────────────────────────────

type AtomKind = enum {
    Copyable
    Callable
    Require
}

// One requirement a bound places on its subject, the type it constrains. `shape` is the
// requirement's or the callable's function type, `TY_VOID` for `Copyable`.
type BoundAtom = struct {
    span: SourceSpan
    subject: Ty
    kind: AtomKind
    // The requirement's function name; empty for the other kinds.
    name: String
    shape: Ty
    // The `where` entry's parameter and the contract it names, for diagnostics.
    param: String
    bound_name: String
    // The bounded type whose parameter bound this atom is, implied by a signature naming it
    // (RFC-036); empty for a `where` entry.
    owner: String
    // Implied by a parameter's type: the argument's type was checked where it was formed, so a call
    // uses the atom to solve and to filter overloads, and does not report it.
    from_param: bool
}

type Verdict = enum {
    Holds
    // The subject is still an open variable: nothing to decide yet.
    Unsettled
    Fails
}

const BOUND_COPYABLE: String = "copyable"
const SELF_NAME: String = "Self"
const MAX_CONTRACT_DEPTH: usize = 16usize
const MAX_BOUND_DEPTH: usize = 4usize

// `$T` names a `where` clause introduces and no parameter does, bound before the return type is
// resolved: `fn sum(it: move $I) T where I: Iterator($T)` returns the `T` its bound solves.
fn prebind_bound_names(self: &Checker, fd: &FunctionDecl) {
    if fd.bounds.len == 0 {
        return
    }
    let names: List(String) = list(0)
    defer names.deinit()
    bound_generic_names(fd, &names)
    for name in names {
        if self.env.lookup(name).is_none() {
            const g = GenericBindType { span = fd.span, name = name }
            const _t = resolve_generic_bind(self, &g)
        }
    }
}

fn lower_bounds(self: &Checker, bounds: TypeBound[], out: &List(BoundAtom)) {
    for &b in bounds {
        const path = bound_path(self, b.param, b.path)
        const subject = path_ty(self, path, b.param, b.span)
        if subject.is_none() {
            push_diag_e(
                self,
                b.span,
                E_BAD_BOUND,
                $"`{path}` is not a type parameter of this function",
            )
            continue
        }
        lower_with_members(self, subject.unwrap(), b.bound, path, b.span, out)
        record_subject_refs(self, b)
    }
}

// Go-to-definition edges for a `where` entry's subject, segment by segment as a projection's.
fn record_subject_refs(self: &Checker, b: &TypeBound) {
    let path = b.param
    for k in 0..b.subject_spans.len {
        if k > 0 {
            path = intern_path(self, path, b.path[k - 1])
        }
        record_type_ref(self, b.subject_spans[k], path)
    }
}

// `param`, or `param.a.b` for a `where I.Item: B` entry.
fn bound_path(self: &Checker, param: String, path: String[]) String {
    let out = param
    for name in path {
        out = intern_path(self, out, name)
    }
    return out
}

// `base.name` as a stable view: binding names, template type-parameter names and `tp_names` entries
// outlive the strings they were built from.
fn intern_path(self: &Checker, base: String, name: String) String {
    let joined = $"{base}.{name}"
    const known = self.paths.get(joined.view)
    if known.is_some() {
        joined.deinit()
        return known.unwrap()
    }
    const view = joined.view
    self.path_bufs.push(joined)
    self.paths.set(view, view)
    return view
}

// One associated type a bound declares, by its path relative to the bound's subject (`Item`,
// `Iter.Item`).
type Member = struct {
    name: String
    ty: Ty
    // The contract's `type Name` declaring it.
    decl: SourceSpan
}

fn member_named(members: &List(Member), name: String) Ty? {
    for &m in members {
        if m.name == name {
            return Some(m.ty)
        }
    }
    return null
}

// A projection's or `where` entry's subject still unpinned when the signature closes.
type PendingProj = struct {
    path: String
    span: SourceSpan
}

// The type `path` names: a type parameter or associated-type path bound in scope. While a signature
// resolves, a path under one of its type parameters that no bound has declared yet gets a
// placeholder, which the declaration unifies with; one never declared is E2142.
fn path_ty(self: &Checker, path: String, root: String, span: SourceSpan) Ty? {
    const b = self.env.lookup(path)
    if b.is_some() and b.unwrap().is_type_param {
        return Some(self.engine.specialize(&b.unwrap().scheme))
    }
    if path == root or !self.sig_open {
        return null
    }
    const r = self.env.lookup(root)
    if r.is_none() or !r.unwrap().is_type_param {
        return null
    }
    const v = self.engine.fresh_var()
    bind_member(self, path, v, span, false, span)
    self.proj_pending.push(PendingProj { path = path, span = span })
    return Some(v)
}

// Binds an associated type's path in the current scope, as a `$T` is bound: inside a signature it
// joins the template's type parameters, so instantiations and the rigid check bind it too. A path
// already bound names the same type - two contracts declaring `Item` on one parameter declare one
// type - so the two unify.
// `decl` is the declaration the path names, for go-to-definition: the contract's `type Item`, or
// the projection itself for a placeholder, which a later declaration repoints.
fn bind_member(
    self: &Checker,
    path: String,
    ty: Ty,
    span: SourceSpan,
    declared: bool,
    decl: SourceSpan,
) {
    if declared and self.sig_open {
        self.sig_declared.push(path)
    }
    const existing = self.env.lookup(path)
    if existing.is_some() and existing.unwrap().is_type_param {
        const have = self.engine.specialize(&existing.unwrap().scheme)
        if !self.engine.unify_exact(have, ty).is_ok() {
            push_diag_e(self, span, E_BAD_BOUND, $"`{path}` is fixed to two different types")
        }
        if declared {
            bind_type_name(self, path, have, decl)
            repoint_sig_tp(self, path, self.node_of(decl))
        }
        return
    }
    bind_type_name(self, path, ty, decl)
    ty_node(self, self.engine.resolve(ty)) match {
        NVar(v) => self.tp_names.set(v.id, path)
        _ => {}
    }
    if self.sig_open {
        self.sig_tps.push(SigTypeParam { name = path, ty = ty, decl = self.node_of(decl) })
    }
}

fn repoint_sig_tp(self: &Checker, name: String, decl: NodeId) {
    for &tp in self.sig_tps {
        if tp.name == name {
            tp.decl = decl
        }
    }
}

// E2142 for each placeholder the signature's bounds never declared.
fn report_undeclared_projections(self: &Checker) {
    for &p in self.proj_pending {
        if !self.sig_declared.contains(p.path) {
            push_diag_e(
                self,
                p.span,
                E_UNKNOWN_ASSOC,
                $"no contract bounding this type parameter declares `{p.path}`",
            )
        }
    }
    self.proj_pending.clear()
}

// `X.Item`, `C.Iter.Item`: the associated type a bound declared, bound by its path.
fn resolve_projection(self: &Checker, p: &ProjectionType) Ty {
    const root = projection_root(p.base)
    const base_path = projection_path(self, p.base)
    if root.is_none() or base_path.is_none() {
        push_diag_e(
            self,
            p.span,
            E_UNKNOWN_ASSOC,
            from_view("a projection reads an associated type of a type parameter: `I.Item`"),
        )
        return TY_ERROR
    }
    const path = intern_path(self, base_path.unwrap(), p.name)
    const found = path_ty(self, path, root.unwrap(), p.span)
    if found.is_some() {
        record_projection_refs(self, p.span, path, p.base)
        return found.unwrap()
    }
    const r = self.env.lookup(root.unwrap())
    if r.is_none() or !r.unwrap().is_type_param {
        push_diag_e(
            self,
            p.span,
            E_UNKNOWN_ASSOC,
            $"`{root.unwrap()}` is not a type parameter - a projection on a concrete type is not a form; write the type itself",
        )
        return TY_ERROR
    }
    push_diag_e(
        self,
        p.span,
        E_UNKNOWN_ASSOC,
        $"no contract bounding `{base_path.unwrap()}` declares `{p.name}`",
    )
    return TY_ERROR
}

// Go-to-definition edges for each segment of a projection: `I.Iter.Item` names the `type Item`
// declaration, `I.Iter` the `type Iter` one, and `I` its `$I`.
fn record_projection_refs(self: &Checker, span: SourceSpan, path: String, base: &TypeExpr) {
    record_type_ref(self, span, path)
    base.* match {
        Named(n) => record_type_ref(self, n.span, n.name)
        Projection(p) => projection_path(self, base) match {
            Some(bp) => record_projection_refs(self, p.span, bp, p.base)
            None => {}
        }
        _ => {}
    }
}

// A use of the type binding `name` at `span`, recorded as a target on the declaration the binding
// names. The signature and resolve passes log it, so a demand skipping them replays it.
fn record_type_ref(self: &Checker, span: SourceSpan, name: String) {
    const b = self.env.lookup(name)
    if b.is_none() or !b.unwrap().is_type_param {
        return
    }
    if self.sig_open {
        self.sig_refs.push(SigRef { span = span, name = name })
    }
    const decl = b.unwrap().decl
    record_ref(self, span, ResolvedTarget.RtType(decl), self.results.get_span(decl))
}

// A use of the nominal `id` at `span` (a type name, an enum qualifier), recorded as a type target
// on its declaration. A synthesized nominal has no declaration to point at.
fn record_nominal_ref(self: &Checker, span: SourceSpan, id: NominalId) {
    const decl_span = self.nominals.get(id).* match {
        NomStruct(sd) => sd.decl_span
        NomEnum(ed) => ed.decl_span
    }
    if decl_span.file_id < 0 {
        return
    }
    record_ref(self, span, ResolvedTarget.RtType(node_id_of(decl_span)), Some(decl_span))
}

// The use of field `name` at `span` on the struct behind `recv`, recorded as a field target.
fn record_field_ref(self: &Checker, recv: Ty, name: String, span: SourceSpan) {
    const hit = field_index(self, recv, name)
    if hit.is_none() {
        return
    }
    record_ref(self, span, ResolvedTarget.RtStructField(hit.unwrap().nom, hit.unwrap().idx), null)
}

// A named initializer or pattern field `name = v` at `span`. The shorthand `name` alone is its
// binding's node, so it records nothing.
fn record_init_ref(self: &Checker, recv: Ty, name: String, span: SourceSpan) {
    if span.length <= name.len {
        return
    }
    record_field_ref(self, recv, name, head_span(span, name.len))
}

type FieldIndex = struct {
    nom: NominalId
    idx: u32
}

fn field_index(self: &Checker, recv: Ty, name: String) FieldIndex? {
    const peeled = peel_refs(self, self.engine.zonk(recv))
    const nom = ty_node(self, peeled) match {
        NNominal(n) => n.id
        _ => return null
    }
    const idx = self.nominals.get(nom).* match {
        NomStruct(sd) => field_position(&sd.fields, name)
        NomEnum(_) => null
    }
    return idx match {
        Some(i) => Some(FieldIndex { nom = nom, idx = i })
        None => null
    }
}

fn field_position(fields: &List(Field), name: String) u32? {
    for i in 0..fields.len {
        if fields[i].name == name {
            return Some(i as u32)
        }
    }
    return null
}

fn tail_span(span: SourceSpan, len: usize) SourceSpan {
    return .{ file_id = span.file_id, start = span.start + span.length - len, length = len }
}

fn head_span(span: SourceSpan, len: usize) SourceSpan {
    return .{ file_id = span.file_id, start = span.start, length = len }
}

// One reference edge (`RtType`, `RtStructField`) at `span`. An expression's own target, which
// lowering reads, is never replaced. The signature and resolve passes log the edge, so a demand
// skipping them replays it.
fn record_ref(self: &Checker, span: SourceSpan, target: ResolvedTarget, decl_span: SourceSpan?) {
    const node = self.node_of(span)
    const prior = self.results.resolved_targets.get(node)
    const keeps = prior match {
        Some(t) => !is_ref_edge(&t)
        None => false
    }
    if keeps {
        return
    }
    if prior.is_none() {
        self.ref_new = self.ref_new + 1
    }
    target match {
        RtType(decl) => {
            if decl_span.is_some() {
                self.results.record_span(decl, decl_span.unwrap())
            }
        }
        _ => {}
    }
    self.results.record_target(node, target)
    if self.ref_logging {
        self.ref_log.push(TypeRefFact {
            node = node,
            span = span,
            target = target,
            decl_span = decl_span,
        })
    }
}

fn is_ref_edge(t: &ResolvedTarget) bool {
    return t.* match {
        RtType(_) => true
        RtStructField(_, _) => true
        _ => false
    }
}

// A type reference made while a signature resolves, recorded again once its bounds are lowered: a
// projection read before the `where` entry declaring it pointed at its placeholder.
type SigRef = struct {
    span: SourceSpan
    name: String
}

fn rerecord_sig_refs(self: &Checker) {
    let refs = replace(&self.sig_refs, list(0))
    defer refs.deinit()
    for &r in refs {
        record_type_ref(self, r.span, r.name)
    }
}

// One reference edge a skipped pass replays: the use's node, span and target, and a type target's
// declaration span.
pub type TypeRefFact = struct {
    node: NodeId
    span: SourceSpan
    target: ResolvedTarget
    decl_span: SourceSpan?
}

fn replay_type_refs(self: &Checker, refs: &List(TypeRefFact)) {
    for &r in refs {
        self.results.record_span(r.node, r.span)
        r.target match {
            RtType(decl) => {
                if r.decl_span.is_some() {
                    self.results.record_span(decl, r.decl_span.unwrap())
                }
            }
            _ => {}
        }
        self.results.record_target(r.node, r.target)
    }
}

// The type-parameter name a projection starts from: `I` in `I.Iter.Item`.
fn projection_root(te: &TypeExpr) String? {
    return te.* match {
        Named(n) => if n.generic_args.len == 0 { Some(n.name) } else { null }
        Projection(p) => projection_root(p.base)
        _ => null
    }
}

fn projection_path(self: &Checker, te: &TypeExpr) String? {
    return te.* match {
        Named(n) => if n.generic_args.len == 0 { Some(n.name) } else { null }
        Projection(p) => projection_path(self, p.base) match {
            Some(base) => Some(intern_path(self, base, p.name))
            None => null
        }
        _ => null
    }
}

// Lowers `te` on `subject` and binds the associated types it declares under `path`.
fn lower_with_members(
    self: &Checker,
    subject: Ty,
    te: &TypeExpr,
    path: String,
    span: SourceSpan,
    out: &List(BoundAtom),
) {
    let members: List(Member) = list(0)
    defer members.deinit()
    lower_bound(self, subject, te, path, "", span, out, &members, 0usize)
    for &m in members {
        bind_member(self, intern_path(self, path, m.name), m.ty, span, true, m.decl)
    }
}

// `label` is the outermost named contract the atoms come from, for diagnostics: `T: Ordered` rather
// than the `Eq` or anonymous part that failed. Empty at the top of a `where` entry. The associated
// types the bound declares land in `members`.
fn lower_bound(
    self: &Checker,
    subject: Ty,
    te: &TypeExpr,
    param: String,
    label: String,
    span: SourceSpan,
    out: &List(BoundAtom),
    members: &List(Member),
    depth: usize,
) {
    if depth > MAX_CONTRACT_DEPTH {
        push_diag_e(
            self,
            span,
            E_BAD_BOUND,
            from_view("contract nests too deeply - is it defined through itself?"),
        )
        return
    }
    te.* match {
        Named(n) => lower_named_bound(self, subject, &n, param, label, span, out, members, depth)
        Function(f) => out.push(BoundAtom {
            span = span,
            subject = subject,
            kind = AtomKind.Callable,
            name = "",
            shape = resolve_function(self, &f),
            param = param,
            bound_name = if label.len > 0 { label } else { "fn" },
            owner = "",
            from_param = false,
        })
        Combined(c) => {
            for &part in c.parts {
                lower_bound(self, subject, part, param, label, span, out, members, depth + 1)
            }
        }
        Contract(c) => lower_contract(
            self,
            subject,
            &c,
            null,
            param,
            if label.len > 0 { label } else { "contract" },
            span,
            out,
            members,
            depth,
        )
        _ => push_diag_e(
            self,
            type_expr_span(te),
            E_BAD_BOUND,
            from_view(
                "a bound is a contract: `copyable`, a contract name, `contract { ... }`, a function type, or a `+` of them",
            ),
        )
    }
}

fn lower_named_bound(
    self: &Checker,
    subject: Ty,
    n: &NamedType,
    param: String,
    label: String,
    span: SourceSpan,
    out: &List(BoundAtom),
    members: &List(Member),
    depth: usize,
) {
    if n.name == BOUND_COPYABLE and n.generic_args.len == 0 and n.assoc_args.len == 0 {
        out.push(BoundAtom {
            span = span,
            subject = subject,
            kind = AtomKind.Copyable,
            name = "",
            shape = TY_VOID,
            param = param,
            bound_name = if label.len > 0 { label } else { BOUND_COPYABLE },
            owner = "",
            from_param = false,
        })
        return
    }
    const own = if label.len > 0 { label } else { n.name }
    const body = contract_body(self, n.name)
    if body.is_none() {
        push_diag_e(self, n.span, E_BAD_BOUND, $"`{n.name}` is not a contract")
        return
    }
    const te = body.unwrap()
    te.* match {
        Contract(c) => {
            let args = resolve_generic_args(self, n)
            let mine: List(Member) = list(c.assoc_types.len)
            lower_contract(self, subject, &c, Some(&args), param, own, span, out, &mine, depth + 1)
            args.deinit()
            apply_assoc_args(self, n, param, span, out, &mine, depth)
            members.push_all(mine.as_slice())
            mine.deinit()
        }
        _ => {
            if n.generic_args.len > 0 {
                push_diag_e(self, n.span, E_BAD_BOUND, $"`{n.name}` takes no type arguments")
            } else if n.assoc_args.len > 0 {
                push_diag_e(
                    self,
                    n.assoc_args[0].span,
                    E_BAD_ASSOC_ARG,
                    $"`{n.name}` is not a single contract, so it has no associated types to constrain",
                )
            } else {
                lower_bound(self, subject, te, param, own, span, out, members, depth + 1)
            }
        }
    }
}

// `Name(Item = T)` pins an associated type the contract declared; `Name(Item: B)` bounds it, as
// `where X.Item: B` would. `T` and `B` resolve in the bound's own scope.
fn apply_assoc_args(
    self: &Checker,
    n: &NamedType,
    param: String,
    span: SourceSpan,
    out: &List(BoundAtom),
    members: &List(Member),
    depth: usize,
) {
    for i in 0..n.assoc_args.len {
        const a = &n.assoc_args[i]
        if assoc_named_before(n.assoc_args, i) {
            push_diag_e(
                self,
                a.span,
                E_BAD_ASSOC_ARG,
                $"`{a.name}` is constrained twice in one application of `{n.name}`",
            )
            continue
        }
        const m = member_named(members, a.name)
        if m.is_none() {
            push_diag_e(
                self,
                a.span,
                E_BAD_ASSOC_ARG,
                $"`{n.name}` declares no associated type `{a.name}`",
            )
            continue
        }
        if a.pinned {
            const t = resolve_type_expr(self, a.ty)
            if !self.engine.unify_exact(m.unwrap(), t).is_ok() {
                push_diag_e(
                    self,
                    a.span,
                    E_BAD_BOUND,
                    $"`{param}.{a.name}` is fixed to two different types",
                )
            }
            continue
        }
        let sub: List(Member) = list(0)
        lower_bound(
            self,
            m.unwrap(),
            a.ty,
            intern_path(self, param, a.name),
            "",
            span,
            out,
            &sub,
            depth + 1,
        )
        for &s in sub {
            members.push(Member {
                name = intern_path(self, a.name, s.name),
                ty = s.ty,
                decl = s.decl,
            })
        }
        sub.deinit()
    }
}

fn assoc_named_before(args: AssocArg[], i: usize) bool {
    for j in 0..i {
        if args[j].name == args[i].name {
            return true
        }
    }
    return false
}

// A declared name's body when it can name a contract: a `type` declaration that is not a struct or
// enum. Lowering decides whether the body is one.
fn contract_body(self: &Checker, name: String) &TypeExpr? {
    let vis = current_visibility(self)
    defer vis.deinit()
    return self.aliases.lookup_ref(name, &vis)
}

fn is_contract_body(te: &TypeExpr) bool {
    return te.* match {
        Contract(_) => true
        Combined(_) => true
        _ => false
    }
}

// One contract applied to `args` on `subject`: `Self` and the contract's parameters bound, each
// associated type a fresh variable the requirements solve, each derived one the type it names. The
// requirements' atoms come first, then the parameters' bounds, then the associated types', which
// read what the requirements solved. The associated types land in `members`.
fn lower_contract(
    self: &Checker,
    subject: Ty,
    c: &ContractType,
    args: &List(Ty)?,
    param: String,
    name: String,
    span: SourceSpan,
    out: &List(BoundAtom),
    members: &List(Member),
    depth: usize,
) {
    const n_args = if args.is_some() { args.unwrap().len } else { 0usize }
    if n_args != c.generics.len {
        push_diag_e(
            self,
            span,
            E_BAD_BOUND,
            $"`{name}` takes {c.generics.len} type argument(s), the bound gives {n_args}",
        )
        return
    }
    self.env.push_scope()
    const self_decl = self.self_decls.get(node_id_of(c.span)) ?? c.span
    bind_type_name(self, SELF_NAME, subject, self_decl)
    for i in 0..c.generics.len {
        const a = args.unwrap()
        bind_type_name(self, c.generics[i].name, a[i], c.generics[i].span)
    }
    let pre: List(BoundAtom) = list(0)
    defer pre.deinit()
    for i in 0..c.generics.len {
        const g = &c.generics[i]
        g.bound match {
            Some(bt) => lower_scoped(self, args.unwrap()[i], bt, g.name, span, &pre, depth + 1)
            None => {}
        }
    }
    let own: List(Member) = list(c.assoc_types.len)
    defer own.deinit()
    for &at in c.assoc_types {
        if at.value.is_none() {
            bind_contract_member(self, at.name, self.engine.fresh_var(), at.span, &own)
        }
    }
    let post: List(BoundAtom) = list(0)
    defer post.deinit()
    for &at in c.assoc_types {
        if at.bound.is_none() {
            continue
        }
        const v = member_named(&own, at.name).unwrap()
        let sub: List(Member) = list(0)
        lower_bound(
            self,
            v,
            at.bound.unwrap(),
            intern_path(self, param, at.name),
            "",
            span,
            &post,
            &sub,
            depth + 1,
        )
        for &s in sub {
            bind_contract_member(self, intern_path(self, at.name, s.name), s.ty, s.decl, &own)
        }
        sub.deinit()
    }
    for &at in c.assoc_types {
        if at.value.is_some() {
            const t = resolve_type_expr(self, at.value.unwrap())
            bind_contract_member(self, at.name, t, at.span, &own)
        }
    }
    for &r in c.requirements {
        out.push(BoundAtom {
            span = span,
            subject = subject,
            kind = AtomKind.Require,
            name = r.name,
            shape = resolve_function(self, &r.signature),
            param = param,
            bound_name = name,
            owner = "",
            from_param = false,
        })
    }
    out.push_all(pre.as_slice())
    out.push_all(post.as_slice())
    members.push_all(own.as_slice())
    self.env.pop_scope()
}

// A contract's associated type, bound inside the contract by its name and as `Self.name`, and
// recorded for the bound's caller.
fn bind_contract_member(self: &Checker, name: String, ty: Ty, span: SourceSpan, own: &List(Member)) {
    bind_type_name(self, name, ty, span)
    bind_type_name(self, intern_path(self, SELF_NAME, name), ty, span)
    own.push(Member { name = name, ty = ty, decl = span })
}

// Lowers `te` on `subject` and binds its associated types under `path` in the current scope alone:
// a contract parameter's bound, read inside the contract.
fn lower_scoped(
    self: &Checker,
    subject: Ty,
    te: &TypeExpr,
    path: String,
    span: SourceSpan,
    out: &List(BoundAtom),
    depth: usize,
) {
    let sub: List(Member) = list(0)
    defer sub.deinit()
    lower_bound(self, subject, te, path, "", span, out, &sub, depth)
    for &s in sub {
        bind_type_name(self, intern_path(self, path, s.name), s.ty, s.decl)
    }
}

// E2140: `Self` names the type being declared and cannot be declared itself.
fn refuse_self_name(self: &Checker, name: String, span: SourceSpan) {
    if name == SELF_NAME {
        push_diag_e(
            self,
            span,
            E_SELF_DECLARED,
            from_view("`Self` is reserved and cannot be declared"),
        )
    }
}

fn bind_type_name(self: &Checker, name: String, ty: Ty, span: SourceSpan) {
    self.env.bind(
        name,
        Binding {
            scheme = mono(ty),
            decl = self.node_of(span),
            is_const = true,
            is_type_param = true,
        },
    )
}

// Atoms can mention variables the function type does not - `T` in `I: Iterator($T)` when nothing
// else names it, an associated type - and each call instantiates those afresh too. Each atom is
// stored zonked: a carried signature outlives the engine whose unifications it reflects.
fn quantify_atoms(self: &Checker, atoms: &List(BoundAtom), q: &Set(VarId)) {
    for &a in atoms {
        a.subject = self.engine.zonk(a.subject)
        a.shape = self.engine.zonk(a.shape)
        free_vars(&self.engine.interner, a.subject, self.engine.level, q)
        free_vars(&self.engine.interner, a.shape, self.engine.level, q)
    }
}

// Each signature type parameter's type, zonked and quantified like the atoms: an associated type
// nothing else mentions is still instantiated per call.
fn settle_sig_tps(self: &Checker, q: &Set(VarId)) {
    for &tp in self.sig_tps {
        tp.ty = self.engine.zonk(tp.ty)
        free_vars(&self.engine.interner, tp.ty, self.engine.level, q)
    }
}

// A struct's or enum's parameter bounds (RFC-036): the atoms over its parameters' variables, the
// associated types they declare by parameter index and path, and the associated types' own
// variables, minted afresh at each application.
type NomBounds = struct {
    atoms: List(BoundAtom)
    members: List(NomMember)
    assoc: Set(VarId)
}

pub fn deinit(self: move NomBounds) {
    self.atoms.deinit()
    self.members.deinit()
    self.assoc.deinit()
}

type NomMember = struct {
    param: usize
    path: String
    ty: Ty
    decl: SourceSpan
}

// Lowers a struct's or enum's parameter bounds (`struct(I: Iterator, F: fn(I.Item) bool)`) on its
// parameters' variables, bound in the current scope. Each parameter's associated types are bound
// under its name, for the bounds after it.
fn lower_type_params(self: &Checker, id: NominalId, generics: GenericParam[]) {
    self.nom_bounds.remove(id) match {
        Some(old) => old.deinit()
        None => {}
    }
    let atoms: List(BoundAtom) = list(0)
    let members: List(NomMember) = list(0)
    self.engine.enter_level()
    for i in 0..generics.len {
        const g = &generics[i]
        if g.bound.is_none() {
            continue
        }
        if names_later_param(generics, i) {
            push_diag_e(
                self,
                g.span,
                E_LATER_PARAM,
                $"the bound on `{g.name}` names a later parameter - a bound reads only the parameters before it",
            )
            continue
        }
        const b = self.env.lookup(g.name)
        if b.is_none() {
            continue
        }
        const subject = self.engine.specialize(&b.unwrap().scheme)
        let sub: List(Member) = list(0)
        lower_bound(self, subject, g.bound.unwrap(), g.name, "", g.span, &atoms, &sub, 0usize)
        for &s in sub {
            bind_member(self, intern_path(self, g.name, s.name), s.ty, g.span, true, s.decl)
            members.push(NomMember { param = i, path = s.name, ty = s.ty, decl = s.decl })
        }
        sub.deinit()
    }
    self.engine.exit_level()
    if atoms.len == 0 {
        atoms.deinit()
        members.deinit()
        return
    }
    let assoc: Set(VarId) = set()
    quantify_atoms(self, &atoms, &assoc)
    for &m in members {
        m.ty = self.engine.zonk(m.ty)
        free_vars(&self.engine.interner, m.ty, self.engine.level, &assoc)
    }
    self.nom_bounds.set(
        id,
        NomBounds { atoms = move atoms, members = move members, assoc = move assoc },
    )
}

// The associated-type variables a resolved field or payload type names (`I.Item`): the variables
// deeper than the declaration's own parameters, which `lower_type_params` minted.
fn collect_assoc_vars(self: &Checker, t: Ty, out: &List(VarId)) {
    let q: Set(VarId) = set()
    defer q.deinit()
    free_vars(&self.engine.interner, self.engine.zonk(t), self.engine.level, &q)
    for v in q {
        if !out.contains(v) {
            out.push(v)
        }
    }
}

// The substitution for a field or payload type of the instance `inst`: its arguments, and the
// associated types its definition's fields name. A ground instance has them solved; elsewhere an
// argument that is a type parameter in scope gives its path binding (`I.Item` inside a generic
// body), and anything else a fresh variable, so a definition's own variables never escape it.
fn member_subst(
    self: &Checker,
    inst: Ty,
    params: &List(VarId),
    assoc: &List(VarId),
    args: ChildSpan,
) Dict(VarId, Ty) {
    if assoc.len > 0 {
        solve_instance(self, inst)
    }
    let subst = self.nominals.instance_subst(inst, params, assoc, args, &self.engine.interner)
    for v in assoc {
        if !subst.contains(v) {
            subst.set(v, open_assoc(self, inst, v, args))
        }
    }
    return subst
}

// An unsolved associated type of `inst`: the path binding of the type parameter it hangs off, or a
// fresh variable.
fn open_assoc(self: &Checker, inst: Ty, v: VarId, args: ChildSpan) Ty {
    const id = ty_node(self, inst) match {
        NNominal(nn) => nn.id
        _ => return self.engine.fresh_var()
    }
    const nb = self.nom_bounds.get_ref(id)
    if nb.is_none() {
        return self.engine.fresh_var()
    }
    for &m in nb.unwrap().members {
        const hit = ty_node(self, self.engine.resolve(m.ty)) match {
            NVar(mv) => mv.id == v
            _ => false
        }
        if !hit or m.param >= args.len {
            continue
        }
        const arg = self.engine.resolve(self.engine.interner.child_at(args, m.param))
        const name = ty_node(self, arg) match {
            NVar(av) => self.tp_names.get(av.id)
            _ => null
        }
        if name.is_none() {
            break
        }
        const b = self.env.lookup(intern_path(self, name.unwrap(), m.path))
        if b.is_some() and b.unwrap().is_type_param {
            return self.engine.specialize(&b.unwrap().scheme)
        }
        break
    }
    return self.engine.fresh_var()
}

// Records what a ground instance's associated types solve to (RFC-036), by checking its
// definition's bounds for its arguments, as a call checks a function's. Every substitution of the
// instance's fields reads the result: the checker's, layout's and lowering's.
fn solve_instance(self: &Checker, inst: Ty) {
    const t = self.engine.zonk(inst)
    if !self.engine.interner.is_ground(t) or self.nominals.assoc_solved.contains(t) {
        return
    }
    const nn = ty_node(self, t) match {
        NNominal(n) => n
        _ => return
    }
    const assoc = nominal_assoc(self, nn.id)
    const nb = self.nom_bounds.get_ref(nn.id)
    if assoc.len == 0 or nb.is_none() or self.bound_depth >= MAX_BOUND_DEPTH {
        return
    }
    const tps = nominal_params(self, nn.id)
    if tps.len != nn.args.len {
        return
    }
    let binds: Dict(VarId, Ty) = dict()
    defer binds.deinit()
    for i in 0..tps.len {
        binds.set(tps[i], self.engine.interner.child_at(nn.args, i))
    }
    for v in nb.unwrap().assoc {
        binds.set(v, self.engine.fresh_var())
    }
    const diags0 = self.diagnostics.len
    self.bound_depth = self.bound_depth + 1
    const switched = enter_view(self, nominal_module(self, nn.id))
    self.engine.push_checkpoint()
    for &a in nb.unwrap().atoms {
        const _v = atom_verdict(self, a, Some(&binds))
    }
    let solved: List(Ty) = list(assoc.len)
    for v in assoc {
        const b = binds.get(v)
        const x = if b.is_some() { self.engine.zonk(b.unwrap()) } else { TY_ERROR }
        solved.push(x)
    }
    self.engine.rollback()
    leave_bound_view(self, switched)
    self.bound_depth = self.bound_depth - 1
    drop_diags_from(self, diags0)
    for x in solved {
        if !self.engine.interner.is_ground(x) or x == TY_ERROR {
            solved.deinit()
            return
        }
    }
    self.nominals.assoc_solved.set(t, solved)
}

fn nominal_assoc(self: &Checker, id: NominalId) &List(VarId) {
    return self.nominals.get(id).* match {
        NomStruct(sd) => &sd.assoc_params
        NomEnum(ed) => &ed.assoc_params
    }
}

fn names_later_param(generics: GenericParam[], i: usize) bool {
    const bound = generics[i].bound.unwrap()
    for j in (i + 1)..generics.len {
        if mentions_name(bound, generics[j].name) {
            return true
        }
    }
    return false
}

// A bounded type applied to `args` (RFC-036). In a signature its bounds are implied: they join the
// function's atoms, and an argument that is one of its type parameters gains the associated types
// they declare (`I.Item` from `FilterIter($I, $F)`). In a body they are checked at the type
// expression (E2134); an argument still open waits for the instantiation that settles it.
fn apply_nominal_bounds(
    self: &Checker,
    id: NominalId,
    args: &List(Ty),
    name: String,
    span: SourceSpan,
) {
    const in_body = self.check_apps and !self.rigid_mode
    if !self.sig_open and !in_body {
        return
    }
    const nb = self.nom_bounds.get_ref(id)
    if nb.is_none() {
        return
    }
    const tps = nominal_params(self, id)
    if tps.len != args.len {
        return
    }
    let binds: Dict(VarId, Ty) = dict()
    defer binds.deinit()
    for i in 0..tps.len {
        binds.set(tps[i], args[i])
    }
    for v in nb.unwrap().assoc {
        binds.set(v, self.engine.fresh_var())
    }
    if self.sig_open {
        imply_bounds(self, nb.unwrap(), &binds, args, name, span)
    } else {
        check_app_bounds(self, id, nb.unwrap(), &binds, name, span)
    }
}

fn nominal_params(self: &Checker, id: NominalId) &List(VarId) {
    return self.nominals.get(id).* match {
        NomStruct(sd) => &sd.type_params
        NomEnum(ed) => &ed.type_params
    }
}

fn nominal_module(self: &Checker, id: NominalId) String {
    return self.nominals.get(id).* match {
        NomStruct(sd) => sd.module
        NomEnum(ed) => ed.module
    }
}

fn imply_bounds(
    self: &Checker,
    nb: &NomBounds,
    binds: &Dict(VarId, Ty),
    args: &List(Ty),
    owner: String,
    span: SourceSpan,
) {
    for &a in nb.atoms {
        const subject = atom_inst(self, a.subject, Some(binds))
        const shape = atom_inst(self, a.shape, Some(binds))
        // Over concrete types the bound is the body check's, at the type expression.
        const ground = self.engine.interner.is_ground(subject)
            and self.engine.interner.is_ground(shape)
        if ground {
            continue
        }
        self.sig_implied.push(BoundAtom {
            span = a.span,
            subject = subject,
            kind = a.kind,
            name = a.name,
            shape = shape,
            param = a.param,
            bound_name = a.bound_name,
            owner = owner,
            from_param = self.sig_params_open,
        })
    }
    for &m in nb.members {
        const base = sig_param_name(self, args[m.param])
        if base.is_some() {
            bind_member(
                self,
                intern_path(self, base.unwrap(), m.path),
                atom_inst(self, m.ty, Some(binds)),
                span,
                true,
                m.decl,
            )
        }
    }
}

// The signature type parameter `t` is, by name: `I` for `$I`'s variable, `I.Iter` for that path's.
fn sig_param_name(self: &Checker, t: Ty) String? {
    const want = ty_node(self, self.engine.resolve(t)) match {
        NVar(v) => v.id
        _ => return null
    }
    for &tp in self.sig_tps {
        const hit = ty_node(self, self.engine.resolve(tp.ty)) match {
            NVar(v) => v.id == want
            _ => false
        }
        if hit {
            return Some(tp.name)
        }
    }
    return null
}

// A bounded type applied in a body: its bounds checked in its defining module's view, as a call's
// are in the callee's, and undone afterwards. Inside an instantiation the failure is reported at
// the call that chose the arguments.
fn check_app_bounds(
    self: &Checker,
    id: NominalId,
    nb: &NomBounds,
    binds: &Dict(VarId, Ty),
    name: String,
    span: SourceSpan,
) {
    if self.bound_depth >= MAX_BOUND_DEPTH {
        return
    }
    const diags0 = self.diagnostics.len
    self.bound_depth = self.bound_depth + 1
    const switched = enter_view(self, nominal_module(self, id))
    self.engine.push_checkpoint()
    let failed: BoundAtom? = null
    let subject = TY_ERROR
    for &a in nb.atoms {
        const fails = atom_verdict(self, a, Some(binds)) match {
            Fails => true
            _ => false
        }
        if fails {
            failed = Some(a.*)
            subject = self.engine.zonk(atom_inst(self, a.subject, Some(binds)))
            break
        }
    }
    self.engine.rollback()
    leave_bound_view(self, switched)
    self.bound_depth = self.bound_depth - 1
    drop_diags_from(self, diags0)
    if failed.is_none() {
        return
    }
    const a = failed.unwrap()
    let sb = string_builder(160)
    sb.append($"`{name}` requires `{a.param}: {a.bound_name}`")
    append_bound_failure(self, &a, subject, &sb)
    own_report(self, span, E_BOUND_UNSATISFIED, sb.to_string())
}

// A contract declaration checked on its own, against a placeholder `Self`: its requirements
// resolve, each mentions `Self` (E2141), its members' bounds are contracts.
fn validate_contract_decl(self: &Checker, td: &TypeDecl) {
    const subject = self.engine.fresh_var()
    const subject_id = ty_node(self, subject) match { NVar(v) => v.id, _ => 0u32 }
    let scratch: List(BoundAtom) = list(0)
    defer scratch.deinit()
    let members: List(Member) = list(0)
    defer members.deinit()
    td.body.* match {
        Contract(c) => {
            let args: List(Ty) = list(c.generics.len)
            for i in 0..c.generics.len {
                const g = &c.generics[i]
                refuse_self_name(self, g.name, g.span)
                if g.bound.is_some() and names_later_param(c.generics, i) {
                    push_diag_e(
                        self,
                        g.span,
                        E_LATER_PARAM,
                        $"the bound on `{g.name}` names a later parameter - a bound reads only the parameters before it",
                    )
                }
                args.push(self.engine.fresh_var())
            }
            lower_contract(
                self,
                subject,
                &c,
                Some(&args),
                SELF_NAME,
                td.name,
                td.span,
                &scratch,
                &members,
                0usize,
            )
            args.deinit()
            for i in 0..c.requirements.len {
                if i < scratch.len and !self.engine.occurs_in(subject_id, scratch[i].shape) {
                    push_diag_e(
                        self,
                        c.requirements[i].span,
                        E_REQUIREMENT_NO_SELF,
                        $"requirement `{c.requirements[i].name}` does not mention `Self`, so no type can be said to satisfy it",
                    )
                }
            }
        }
        _ => lower_bound(self, subject, td.body, SELF_NAME, "", td.span, &scratch, &members, 0usize)
    }
    self.sig_tps.clear()
}

// Whether the function `fid`'s bounds make the type parameter `vid` copyable: a `copyable` atom on
// it, from a `where` entry, a contract that includes `copyable`, or a type its signature names.
fn copyable_in_bounds(self: &Checker, fid: u32, vid: VarId) bool {
    const atoms = self.fn_bounds.get_ref(fid)
    if atoms.is_none() {
        return false
    }
    for &a in atoms.unwrap() {
        const is_copy = a.kind match {
            Copyable => true
            _ => false
        }
        if !is_copy {
            continue
        }
        const hit = ty_node(self, self.engine.resolve(a.subject)) match {
            NVar(v) => v.id == vid
            _ => false
        }
        if hit {
            return true
        }
    }
    return false
}

// ── Satisfaction ──

fn atom_inst(self: &Checker, t: Ty, binds: &Dict(VarId, Ty)?) Ty {
    const z = self.engine.zonk(t)
    if binds.is_none() {
        return z
    }
    return self.engine.zonk(self.engine.substitute_shared(z, binds.unwrap()))
}

// Whether `a` holds under `binds`. The unifications that decide it - solving `$T`, typing a
// lambda's parameters - stay in place; the caller owns the speculative region around them.
fn atom_verdict(self: &Checker, a: &BoundAtom, binds: &Dict(VarId, Ty)?) Verdict {
    const subject = self.engine.resolve(atom_inst(self, a.subject, binds))
    if subject.is_error() {
        return Verdict.Holds
    }
    // A rigid parameter of the body being checked is copyable exactly when its own bounds say so;
    // what else it satisfies waits for the instantiation.
    const copyable_atom = a.kind match {
        Copyable => true
        _ => false
    }
    const decidable = !self.engine.is_var(subject) or copyable_atom
        and self.engine.is_rigid(subject)
    if !decidable {
        return Verdict.Unsettled
    }
    return a.kind match {
        Copyable => if ty_copyable(self, subject) { Verdict.Holds } else { Verdict.Fails }
        Callable => callable_verdict(self, subject, atom_inst(self, a.shape, binds), a.span)
        Require => require_verdict(self, a.name, atom_inst(self, a.shape, binds), a.span)
    }
}

// A requirement holds when the call it describes resolves, as a method call on its first parameter,
// and returns exactly the declared type.
fn require_verdict(self: &Checker, name: String, shape: Ty, span: SourceSpan) Verdict {
    const f = ty_node(self, self.engine.resolve(shape)) match {
        NFunc(x) => x
        _ => return Verdict.Fails
    }
    if f.params.len == 0 {
        return Verdict.Fails
    }
    let extra: List(Ty) = list(f.params.len)
    defer extra.deinit()
    for i in 1..f.params.len {
        extra.push(self.engine.interner.child_at(f.params, i))
    }
    const pick = satisfy_pick(self, name, self.engine.interner.child_at(f.params, 0), &extra, span)
    const op = operator_named(name)
    if pick.is_some() or op.is_none() or f.params.len != 2 {
        return returns_exactly(self, pick, f.ret)
    }
    const l = self.engine.interner.child_at(f.params, 0)
    return operator_verdict(self, op.unwrap(), l, extra[0], f.ret, span)
}

// An operator function and its operator are one thing (spec 5.2), so a comparison requirement holds
// wherever the comparison applies: the tag compare of a payload-less enum, or one derived from
// `op_ne` or `op_cmp`. A primitive's own functions are declared (core.ops) and resolve as calls
// before this.
fn operator_verdict(self: &Checker, op: BinaryOp, l: Ty, r: Ty, ret: Ty, span: SourceSpan) Verdict {
    const lr = self.engine.resolve(l)
    const rr = self.engine.resolve(r)
    const is_eq_shape = op match {
        Eq => true
        Ne => true
        _ => false
    }
    if is_eq_shape and payloadless_enum(self, lr) and payloadless_enum(self, rr) {
        const ok = self.engine.unify_exact(lr, rr).is_ok()
            and self.engine.unify_exact(prim_of(PrimitiveKind.Bool), ret).is_ok()
        return if ok { Verdict.Holds } else { Verdict.Fails }
    }
    const m = operator_match(self, op, span, lr, rr, true)
    if m.is_none() {
        return Verdict.Fails
    }
    const found = m.unwrap()
    const result = found.ret
    found.pick.deinit()
    return if self.engine.unify_exact(result, ret).is_ok() { Verdict.Holds } else {
        Verdict.Fails
    }
}

// The comparison an `op_*` function name stands for.
fn operator_named(name: String) BinaryOp? {
    return name match {
        "op_eq" => Some(BinaryOp.Eq)
        "op_ne" => Some(BinaryOp.Ne)
        "op_lt" => Some(BinaryOp.Lt)
        "op_gt" => Some(BinaryOp.Gt)
        "op_le" => Some(BinaryOp.Le)
        "op_ge" => Some(BinaryOp.Ge)
        _ => null
    }
}

fn returns_exactly(self: &Checker, pick: move OverloadPick?, ret: Ty) Verdict {
    if pick.is_none() {
        return Verdict.Fails
    }
    const p = pick.unwrap()
    const ok = self.engine.unify_exact(p.ret, ret).is_ok()
    p.deinit()
    return if ok { Verdict.Holds } else { Verdict.Fails }
}

// A callable bound holds for a function value, a closure, or a nominal with an `op_call` taking the
// bound's arguments.
fn callable_verdict(self: &Checker, callee: Ty, shape: Ty, span: SourceSpan) Verdict {
    const want = ty_node(self, self.engine.resolve(shape)) match {
        NFunc(x) => x
        _ => return Verdict.Fails
    }
    const direct = ty_node(self, callee) match {
        NFunc(have) => Some(have)
        _ => null
    }
    if direct.is_some() {
        return callable_fits(self, &direct.unwrap(), &want)
    }
    const closure = closure_of(self, callee)
    if closure.is_some() {
        return closure_fits(self, closure.unwrap(), &want)
    }
    let extra: List(Ty) = list(want.params.len)
    defer extra.deinit()
    for i in 0..want.params.len {
        extra.push(self.engine.interner.child_at(want.params, i))
    }
    // A `fn(...)` bound calls its callable through `&Self`: it never consumes it.
    const pick = satisfy_pick(self, "op_call", self.engine.mk_ref(callee), &extra, span)
    return returns_exactly(self, pick, want.ret)
}

fn callable_fits(self: &Checker, have: &NFuncNode, want: &NFuncNode) Verdict {
    if have.params.len != want.params.len {
        return Verdict.Fails
    }
    for i in 0..have.params.len {
        if !param_fits(
            self,
            self.engine.interner.child_at(have.params, i),
            moves_at(have, i),
            want,
            i,
        ) {
            return Verdict.Fails
        }
    }
    return if self.engine.unify_exact(have.ret, want.ret).is_ok() { Verdict.Holds } else {
        Verdict.Fails
    }
}

fn closure_fits(self: &Checker, c: &ClosureSig, want: &NFuncNode) Verdict {
    if c.params.len != want.params.len {
        return Verdict.Fails
    }
    for i in 0..c.params.len {
        if !param_fits(self, c.params[i], false, want, i) {
            return Verdict.Fails
        }
    }
    return if self.engine.unify_exact(c.ret, want.ret).is_ok() { Verdict.Holds } else {
        Verdict.Fails
    }
}

// One parameter of a callable against the bound's. A callable may ask no more than the bound
// allows: a reading parameter fits a `&T` or a `move T` slot, a `move` one only a `move` slot (an
// open parameter takes the bound's type as it stands).
fn param_fits(self: &Checker, have: Ty, have_move: bool, want: &NFuncNode, i: usize) bool {
    if have_move and !moves_at(want, i) {
        return false
    }
    const wp = self.engine.resolve(self.engine.interner.child_at(want.params, i))
    const hp = self.engine.resolve(have)
    const reads = !self.engine.is_var(hp) and ty_node(self, hp) match {
        NRef(_) => false
        _ => true
    }
    if reads {
        const inner = ty_node(self, wp) match {
            NRef(x) => Some(x)
            _ => null
        }
        if inner.is_some() {
            return self.engine.unify_exact(hp, inner.unwrap()).is_ok()
        }
    }
    return self.engine.unify_exact(hp, wp).is_ok()
}

// `fid`'s bounds under `binds`: the first atom that fails, and how many were seen to hold.
type BoundCheck = struct {
    failed: BoundAtom?
    held: u32
}

// Checks `fid`'s bounds in a speculative region, kept when nothing failed and `keep` is set, undone
// otherwise; the diagnostics the probing calls raise are dropped either way. `with_copyable` false
// leaves `copyable` to the drain, which reports it with its derivation.
fn check_bounds(
    self: &Checker,
    fid: u32,
    binds: &Dict(VarId, Ty)?,
    keep: bool,
    with_copyable: bool,
) BoundCheck {
    const atoms = self.fn_bounds.get_ref(fid)
    if atoms.is_none() or self.bound_depth >= MAX_BOUND_DEPTH {
        return BoundCheck { failed = null, held = 0u32 }
    }
    const diags0 = self.diagnostics.len
    self.bound_depth = self.bound_depth + 1
    const switched = enter_bound_view(self, fid)
    self.engine.push_checkpoint()
    let failed: BoundAtom? = null
    let held = 0u32
    for &a in atoms.unwrap() {
        const skip = !with_copyable and a.kind match {
            Copyable => true
            _ => false
        }
        if skip {
            continue
        }
        atom_verdict(self, a, binds) match {
            Holds => held = held + 1u32
            Unsettled => {}
            Fails => {
                failed = Some(a.*)
                break
            }
        }
    }
    if failed.is_none() and keep {
        self.engine.commit()
    } else {
        self.engine.rollback()
    }
    leave_bound_view(self, switched)
    self.bound_depth = self.bound_depth - 1
    drop_diags_from(self, diags0)
    return BoundCheck { failed = failed, held = held }
}

// Requirements resolve as the instantiated body will (spec 2.3.0): in `fid`'s defining module, with
// what the calling module makes visible unioned in, so a bound never holds on a function the body
// cannot call. True when the view was switched; `leave_bound_view` restores it.
fn enter_bound_view(self: &Checker, fid: u32) bool {
    const template = self.templates.get_ref(fid)
    if template.is_none() {
        return false
    }
    return enter_view(self, template.unwrap().module)
}

// Resolution from `home`, with the current module's view unioned in. True when the view was
// switched; `leave_bound_view` restores it.
fn enter_view(self: &Checker, home: String) bool {
    if self.current_module.is_none() {
        return false
    }
    const here = self.current_module.unwrap()
    if home == here {
        return false
    }
    self.spec_callers.push(here)
    self.current_module = Some(home)
    return true
}

fn leave_bound_view(self: &Checker, switched: bool) {
    if !switched {
        return
    }
    self.current_module = Some(self.spec_callers.pop().unwrap())
}

fn drop_diags_from(self: &Checker, from: usize) {
    while self.diagnostics.len > from {
        self.diagnostics.pop().unwrap().deinit()
    }
}

// A call's bounds against the types it bound, reported at the call that chose them - the outermost
// open instantiation when the call sits in a generic body. False when one fails: the body is not
// instantiated for a call the signature rejects. A bound a parameter's type implies was the
// argument type's to meet where it was formed (RFC-036), so its failure is reported here only when
// nothing has been: a type formed unchecked still gets a diagnostic.
fn check_call_bounds(self: &Checker, p: &PendingSpec) bool {
    const atoms = self.fn_bounds.get_ref(p.function_id)
    if atoms.is_none() {
        return true
    }
    let ok = true
    const formed_reported = has_errors(self)
    // One report per `where` entry: its first failing requirement.
    let reported: List(SourceSpan) = list(0)
    defer reported.deinit()
    for &a in atoms.unwrap() {
        const diags0 = self.diagnostics.len
        self.bound_depth = self.bound_depth + 1
        const switched = enter_bound_view(self, p.function_id)
        self.engine.push_checkpoint()
        const fails = atom_verdict(self, a, Some(&p.tp_binds)) match {
            Fails => true
            _ => false
        }
        leave_bound_view(self, switched)
        self.bound_depth = self.bound_depth - 1
        if fails {
            self.engine.rollback()
        } else {
            self.engine.commit()
        }
        drop_diags_from(self, diags0)
        if fails {
            ok = false
            const silent = a.from_param and formed_reported
            if !silent and !span_listed(&reported, a.span) {
                reported.push(a.span)
                report_bound(self, p, a)
            }
        }
    }
    return ok
}

fn has_errors(self: &Checker) bool {
    for &d in self.diagnostics {
        const is_error = d.severity match {
            Error => true
            _ => false
        }
        if is_error {
            return true
        }
    }
    return false
}

fn span_listed(spans: &List(SourceSpan), span: SourceSpan) bool {
    for &s in spans {
        if s.start == span.start and s.length == span.length and s.file_id == span.file_id {
            return true
        }
    }
    return false
}

fn report_bound(self: &Checker, p: &PendingSpec, a: &BoundAtom) {
    const template = self.templates.get_ref(p.function_id)
    const fname = if template.is_some() { template.unwrap().decl.name } else { "" }
    const subject = atom_inst(self, a.subject, Some(&p.tp_binds))
    let sb = string_builder(160)
    sb.append($"`{fname}` requires `{a.param}: {a.bound_name}`")
    if a.owner.len > 0 {
        sb.append($" (a bound of `{a.owner}`)")
    }
    append_bound_failure(self, a, subject, &sb)
    own_report(self, p.span, E_BOUND_UNSATISFIED, sb.to_string())
}

// Why `a` fails on `subject`: the copy blame, or the callable or requirement it lacks.
fn append_bound_failure(self: &Checker, a: &BoundAtom, subject: Ty, sb: &StringBuilder) {
    a.kind match {
        Copyable => append_copy_blame(self, subject, sb)
        Callable => {
            sb.append(": `")
            append_ty(self, subject, sb)
            sb.append("` is not callable as `")
            append_ty(self, shape_for(self, a, subject), sb)
            sb.append("`")
        }
        Require => {
            sb.append(": `")
            append_ty(self, subject, sb)
            sb.append($"` has no `{a.name}` of type `")
            append_ty(self, shape_for(self, a, subject), sb)
            sb.append("`")
        }
    }
}

// An atom's shape as declared, with its subject replaced by the type it was checked against: the
// other parameters keep their declared names.
fn shape_for(self: &Checker, a: &BoundAtom, subject: Ty) Ty {
    const sv = ty_node(self, self.engine.resolve(a.subject)) match {
        NVar(v) => Some(v.id)
        _ => null
    }
    if sv.is_none() {
        return a.shape
    }
    let one: Dict(VarId, Ty) = dict()
    defer one.deinit()
    one.set(sv.unwrap(), subject)
    return self.engine.substitute_shared(a.shape, &one)
}

fn append_ty(self: &Checker, t: Ty, sb: &StringBuilder) {
    format_with_names(
        &self.engine.interner,
        self.engine.zonk(t),
        sb,
        Some(&self.nominals),
        Some(&self.tp_names),
    )
}

fn report_uninferable_spec(self: &Checker, p: &PendingSpec) {
    self.slot_uninferable = self.slot_uninferable + 1
    let name = self.templates.get_ref(p.function_id).unwrap().decl.name
    push_diag_e(
        self,
        p.span,
        E_UNINFERRED,
        $"cannot infer the type arguments of generic function `{name}` at this call site",
    )
}

fn process_pending(self: &Checker, p: &PendingSpec) {
    // The call site's instantiated signature, settled by now. Any var still free means inference
    // never pinned a type argument.
    let params: List(Ty) = list(p.inst_params.len)
    for i in 0..p.inst_params.len {
        params.push(self.engine.zonk(p.inst_params[i]))
    }
    let ret = self.engine.zonk(p.inst_ret)
    if !check_call_bounds(self, p) {
        params.deinit()
        return
    }
    if self.slot_log_on and self.spec_depth == 0 and !p.from_parked {
        log_pick(self, p, &params, ret)
    }
    // Readiness is the drain's business (`pending_ready`); by here the only free vars left sit
    // inside callable slots, which the body pins.

    const v0 = self.engine.var_counter
    const s0 = self.next_synth
    const l0 = self.next_lambda

    let key = key_for(&self.engine.interner, p.function_id, &params, ret)
    let existing = self.specs.lookup(key.view)
    if existing.is_none() {
        // A provisional key that misses can still name a carried entry - one whose stored key was
        // re-keyed to its settled signature, or renders variables. The call site is the stable
        // identity then.
        existing = find_spec_hint(self, p.span, p.function_id)
        if existing.is_some() and self.specs.find(existing.unwrap()).is_none() {
            existing = null
        }
    }
    let id = existing match {
        Some(sid) => resolve_against(self, p, key, params, ret, sid)
        None => instantiate(self, p, key, params, ret)
    }

    // Whatever the resolution minted - an instantiation's frame, a reuse's burns - is nested work
    // from the enclosing frame's point of view: its own burns subtract it out.
    if self.spec_frames.len > 0 {
        const last = self.spec_frames.len - 1
        let fr = &self.spec_frames[last]
        fr.child_vars = fr.child_vars + (self.engine.var_counter - v0)
        fr.child_synth = fr.child_synth + (self.next_synth - s0)
        fr.child_lambda = fr.child_lambda + (self.next_lambda - l0)
        if id.is_some() {
            fr.deps.push(SpecDep { span = p.span, function_id = p.function_id, id = id.unwrap() })
        }
    } else if self.site_log_on and id.is_some() {
        self.slot_sites.push(SpecDep {
            span = p.span,
            function_id = p.function_id,
            id = id.unwrap(),
        })
    }
    if id.is_none() {
        return
    }

    // Rewrite the pick's table entry so lowering calls the specialization's symbol. `self.results`
    // is the table set the pick was recorded into - the program tables at top level, the owning
    // instantiation's overlay during a nested drain.
    let node = self.node_of(p.span)
    if p.deref_index.is_some() and p.deref_on_arg {
        self.results.update_arg_deref(
            node,
            p.deref_index.unwrap(),
            ResolvedTarget.RtSpecialized(id.unwrap()),
        )
    } else if p.deref_index.is_some() {
        self.results.update_receiver_deref(
            node,
            p.deref_index.unwrap(),
            ResolvedTarget.RtSpecialized(id.unwrap()),
        )
    } else if p.is_operator {
        let cur = self.results.resolved_ops.get(node)
        if cur.is_some() {
            let op = cur.unwrap()
            self.results.record_operator(node, with_spec(&op, id.unwrap()))
        }
    } else {
        self.results.record_target(node, ResolvedTarget.RtSpecialized(id.unwrap()))
    }
}

// A pick that landed on an existing entry. Alive this demand means plain reuse, exactly the old
// keyed-lookup hit. Carried from an earlier demand means either a replay - counters burned, closure
// environments re-registered, deps touched - or, when the entry or anything under it cannot be
// replayed from here, an in-place re-instantiation at the id it holds.
fn resolve_against(
    self: &Checker,
    p: &PendingSpec,
    key: move OwnedString,
    params: move List(Ty),
    ret: Ty,
    sid: SpecId,
) SpecId? {
    const alive = self.specs.get(sid).touched_gen == self.specs.gen
    if !alive {
        let ok = pick_concrete(self, p, &params, ret)
        if ok {
            let trial: Set(SpecId) = set()
            const pos = StreamPos {
                v = self.engine.var_counter,
                s = self.next_synth,
                l = self.next_lambda,
            }
            ok = spec_probe(self, sid, pos, &trial).is_some()
            trial.deinit()
        }
        if !ok {
            return instantiate(self, p, key, params, ret, Some(sid))
        }
        touch_spec(self, sid)
    }
    key.deinit()
    params.deinit()
    return Some(sid)
}

// Whether the pick's whole instantiated signature - parameters, return and every type-parameter
// bind - is free of engine variables. A non-concrete pick's body re-check pins caller variables,
// which a reuse cannot replay.
fn pick_concrete(self: &Checker, p: &PendingSpec, params: &List(Ty), ret: Ty) bool {
    if !sig_concrete(self, params, ret) {
        return false
    }
    let q: Set(VarId) = set()
    for e in p.tp_binds {
        free_vars(&self.engine.interner, self.engine.zonk(e.value), 0u32, &q)
    }
    let n = q.len()
    q.deinit()
    return n == 0
}

// Whether the carried entry at `sid` - and, transitively, everything its frame's drain resolved -
// can be replayed starting from `pos`. Simulates the burns without committing anything; `trial`
// holds the entries the simulation has already accounted for (a self-recursive generic cites its
// own key). Returns the position after the subtree, or null when anything blocks: a stale template,
// a non-replayable frame, an evicted dep, or a stream anchor that no longer matches - the cached
// closure symbols bake counter values, so a shifted stream would collide with live mints.
fn spec_probe(self: &Checker, sid: SpecId, pos: StreamPos, trial: &Set(SpecId)) StreamPos? {
    const found = self.specs.find(sid)
    if found.is_none() {
        return null
    }
    const sp = found.unwrap()
    if sp.touched_gen == self.specs.gen or trial.contains(sid) {
        return Some(pos)
    }
    if sp.stale or !sp.reusable {
        return null
    }
    if sp.vars_at != pos.v or sp.synth_at != pos.s or sp.lambda_at != pos.l {
        return null
    }
    trial.add(sid)
    let cur = StreamPos {
        v = pos.v + sp.own_var_burn,
        s = pos.s + sp.own_synth_burn,
        l = pos.l + sp.own_lambda_burn,
    }
    for d in sp.deps {
        const r = spec_probe(self, d.id, cur, trial)
        if r.is_none() {
            return null
        }
        cur = r.unwrap()
    }
    return Some(cur)
}

// Replay a carried entry: stamp it live, burn the counters its frame minted, re-register its
// closure environments, then touch what its drain resolved - a dep first touched here burns at the
// position the cold drain minted it.
fn touch_spec(self: &Checker, sid: SpecId) {
    const sp = self.specs.find(sid).unwrap()
    if sp.touched_gen == self.specs.gen {
        return
    }
    self.specs.stamp_touched(sid)
    for _k in 0..(sp.own_var_burn as usize) {
        self.engine.burn_var()
    }
    self.next_synth = self.next_synth + sp.own_synth_burn
    self.next_lambda = self.next_lambda + sp.own_lambda_burn
    for &f in sp.closures {
        replay_closure(self, f)
    }
    for d in sp.deps {
        touch_spec(self, d.id)
    }
}

// The reuse hint for a call site whose provisional key missed the registry: an in-place
// re-instantiation matches its nested picks against the previous incarnation's deps; a slot's
// top-level picks match against the previous demand's site list.
fn find_spec_hint(self: &Checker, span: SourceSpan, function_id: u32) SpecId? {
    if self.spec_frames.len > 0 {
        return hint_in(&self.spec_frames[self.spec_frames.len - 1].hints, span, function_id)
    }
    return hint_in(&self.slot_hints, span, function_id)
}

fn hint_in(hints: &List(SpecDep), span: SourceSpan, function_id: u32) SpecId? {
    for &h in hints {
        if h.function_id == function_id and h.span.file_id == span.file_id
            and h.span.start == span.start and h.span.length == span.length {
            return Some(h.id)
        }
    }
    return null
}

// Unify every parked anonymous literal's field initializers against its now-known nominal's
// declared field types. Reverse insertion order so an outer literal's unifications bind the vars
// its nested literals need (literals check bottom-up, so inner entries were pushed first). A
// literal whose var never resolved to a struct is left alone - its unpinned numeric fields fall
// through to `validate_literals`.
fn resolve_anon_literals(self: &Checker) {
    let i = self.pending_anons.len
    while i > 0 {
        i = i - 1
        let pa = &self.pending_anons[i]
        let z = self.engine.zonk(pa.ty)
        // Nothing pinned the literal: it IS its own record type, so intern the structural nominal
        // its fields describe (`let a = .{ x, y }`). The reference does the same eagerly - here it
        // waits until inference settles so a literal that DOES have a context (a `let` annotation,
        // a parameter, a return type) still unifies with the declared nominal instead of minting a
        // twin.
        let unpinned = self.engine.is_var(z)
        if unpinned {
            let fields: List(Field) = list(pa.fields.len)
            for &rec in pa.fields {
                fields.push(Field {
                    name = rec.name,
                    ty = self.engine.zonk(rec.ty),
                    decl_span = rec.span,
                    owned = false,
                })
            }
            let span = if pa.fields.len > 0 { pa.fields[0].span } else { synth_span(self) }
            const o = self.engine.unify(pa.ty, anon_struct_ty(self, fields, span))
            report_unify(self, &o, E_TYPE_MISMATCH, span)
            continue
        }
        let present: List(String) = list(pa.fields.len)
        defer present.deinit()
        for &rec in pa.fields {
            present.push(rec.name)
            let fty = struct_field_lookup(self, z, rec.name)
            if fty.is_some() {
                record_init_ref(self, z, rec.name, rec.span)
                const o = self.engine.unify(rec.ty, fty.unwrap())
                report_unify(self, &o, E_TYPE_MISMATCH, rec.span)
            }
        }
        // An unpinned literal IS its own record type, so it cannot be missing a field; only one the
        // context bound to a declared nominal can.
        const aspan = if pa.fields.len > 0 { pa.fields[0].span } else { synth_span(self) }
        report_missing_fields(self, z, &present, aspan)
    }
    self.pending_anons.clear()
}

// Report every unsuffixed numeric literal in `pending_literals[from..to]` whose var never resolved.
// A slot sweeps its own range after its drains, so literals inside the template bodies it
// instantiated (whose vars bound during the re-check) count as resolved; the engine's bindings are
// global, so the sweep covers the program tables and every overlay alike. Nothing after a module's
// slot can pin the slot's literals - a later slot reuses a specialization by key without
// re-checking its body - so the per-slot verdict is the program-wide one.
fn validate_literals(self: &Checker, from: usize, to: usize) {
    for k in from..to {
        const pl = self.pending_literals[k]
        let z = self.engine.zonk(pl.ty)
        let unresolved = self.engine.is_var(z)
        if unresolved {
            let kind = if pl.is_float { "float" } else { "integer" }
            push_diag_e(
                self,
                pl.span,
                E_UNINFERRED,
                $"Cannot determine concrete type for {kind} literal `{pl.text}`",
            )
            continue
        }
        // The literal settled on a type - it has to be one a numeric literal can BE (E2102), and
        // the value has to fit it (E2029).
        ty_node(self, z) match {
            NPrim(p) => {
                if !literal_prim_ok(p, pl.is_float) {
                    push_diag_e(
                        self,
                        pl.span,
                        E_PRIM_CONSTRAINT,
                        $"type mismatch: expected one of the numeric types, got `{prim_name(p)}` for literal `{pl.text}`",
                    )
                } else if !pl.is_float {
                    check_int_range(self, pl.text, p, pl.span)
                }
            }
            // Anything that is not a primitive: a numeric literal cannot BE it. Unification rejects
            // that binding in the first place (every literal var carries a `PrimSet`), so this is
            // the backstop for a var that reached a non-primitive some other way - without it such
            // a literal reaches lowering and is emitted as whatever its bytes happen to mean. The
            // engine's poison and a diverging context are not mismatches: `Error` already carries a
            // diagnostic, and `never` absorbs any type by definition.
            _ => {
                if z != TY_ERROR and z != TY_NEVER {
                    let sb = string_builder(64)
                    sb.append("type mismatch: expected one of the numeric types, got `")
                    format_with_names(&self.engine.interner, z, &sb, Some(&self.nominals))
                    sb.append($"` for literal `{pl.text}`")
                    push_diag_e(self, pl.span, E_PRIM_CONSTRAINT, sb.to_string())
                }
            }
        }
    }
}

// Whether `validate_literals` would report this literal, given the engine's bindings. Pure read - a
// slot uses it after its sweep to decide whether its literal verdicts can be skipped on a replay (a
// flagged literal keeps its module running, since the window's sweep is not replayed).
fn literal_flagged(self: &Checker, pl: &PendingLit) bool {
    let z = self.engine.zonk(pl.ty)
    if self.engine.is_var(z) {
        return true
    }
    let p = ty_node(self, z) match {
        NPrim(pk) => pk
        _ => return z != TY_ERROR and z != TY_NEVER
    }
    if !literal_prim_ok(p, pl.is_float) {
        return true
    }
    if pl.is_float {
        return false
    }
    return int_out_of_range(pl.text, p)
}

// What a numeric literal may settle on: any numeric primitive, plus `char` for an integer literal
// (a code point). `bool` is never one - that is the shape E2102 catches when a `$T` picks up
// conflicting bindings (`same(1, true)`).
fn literal_prim_ok(p: PrimitiveKind, is_float: bool) bool {
    if is_float {
        return is_float(p)
    }
    return is_numeric(p) or p == PrimitiveKind.Char
}

// Reject an integer literal that does not fit its resolved type. The value is parsed as an unsigned
// magnitude (the lexer never includes a sign - `-1` is a negation applied to `1`), so the bound
// checked is the type's largest magnitude: `MAX` for unsigned, `MAX + 1` for signed so `-128i8` and
// `128i8` are told apart by the negation, exactly as the reference does.
fn check_int_range(self: &Checker, text: String, p: PrimitiveKind, span: SourceSpan) {
    if int_out_of_range(text, p) {
        push_diag_e(
            self,
            span,
            E_LITERAL_RANGE,
            $"integer literal `{text}` is out of range for `{prim_name(p)}`",
        )
    }
}

fn int_out_of_range(text: String, p: PrimitiveKind) bool {
    if !is_integer(p) {
        return false
    }
    let v = parse_int_magnitude(text)
    if v.is_none() {
        return false
    }
    return v.unwrap() > int_magnitude_limit(p)
}

// The largest magnitude a literal of this primitive may spell.
fn int_magnitude_limit(p: PrimitiveKind) u64 {
    return p match {
        I8 => 128u64
        I16 => 32768u64
        I32 => 2147483648u64
        I64 => 9223372036854775808u64
        ISize => 9223372036854775808u64
        U8 => 255u64
        U16 => 65535u64
        U32 => 4294967295u64
        _ => 18446744073709551615u64
    }
}

// Decimal / hex / binary / octal magnitude of a literal's text, or null when it is not one of those
// forms (or overflows u64 while scanning).
fn parse_int_magnitude(text: String) u64? {
    if text.len == 0 {
        return null
    }
    let base = 10u64
    let i = 0usize
    if text.len > 2 and text[0] == '0' {
        const c1 = text[1]
        if c1 == 'x' or c1 == 'X' {
            base = 16u64
            i = 2
        }
        else if c1 == 'b' or c1 == 'B' {
            base = 2u64
            i = 2
        }
        else if c1 == 'o' or c1 == 'O' {
            base = 8u64
            i = 2
        }
    }
    let n = 0u64
    let any = false
    while i < text.len {
        const c = text[i]
        i = i + 1
        if c == '_' {
            continue
        }
        let d = 0u64
        if c >= '0' and c <= '9' {
            d = (c as u64) - 48u64
        }
        else if c >= 'a' and c <= 'f' {
            d = (c as u64) - 87u64
        }
        else if c >= 'A' and c <= 'F' {
            d = (c as u64) - 55u64
        }
        else {
            return null
        }
        if d >= base {
            return null
        }
        n = n * base + d
        any = true
    }
    if !any {
        return null
    }
    return Some(n)
}

// No free type variable anywhere in the instantiated signature.
fn sig_concrete(self: &Checker, params: &List(Ty), ret: Ty) bool {
    let q: Set(VarId) = set()
    for i in 0..params.len {
        free_vars(&self.engine.interner, params[i], 0u32, &q)
    }
    free_vars(&self.engine.interner, ret, 0u32, &q)
    let n = q.len()
    q.deinit()
    return n == 0
}

// Register and check one new specialization. Registration happens BEFORE the body re-check so a
// self-recursive generic resolves to its own key instead of recursing forever. Returns null (with a
// diagnostic) when the instantiation chain is implausibly deep. `at` re-registers a carried entry
// in place - same id, fresh overlay - handing its previous dep list to the frame as nested reuse
// hints.
// A generic body checked once against rigid type parameters (RFC-029): each `$T` is a type of its
// own, copyable only under `where T: copyable`, so copying a value of a type parameter is refused
// where the body writes it. What is dispatched on `T` fails against a rigid one and waits for an
// instantiation, so the check runs in scratch tables and keeps the ownership findings alone,
// including the `copyable` bounds of the generics it calls.
fn check_template_rigid(self: &Checker, fd: &FunctionDecl) {
    const fid = template_id_of(self, fd)
    if fid.is_none() {
        return
    }

    const diags0 = self.diagnostics.len
    const calls0 = self.pending_calls.len
    let saved_results = replace(&self.results, inference_results())
    let saved_pending = replace(&self.pending_specs, list(0))
    let saved_literals = replace(&self.pending_literals, list(0))
    let saved_anons = replace(&self.pending_anons, list(0))
    let saved_members = replace(&self.pending_members, list(0))
    let saved_fn_names = replace(&self.pending_fn_names, list(0))

    self.env.push_scope()
    self.rigid_fid = fid.unwrap()
    self.rigid_tvars.clear()
    bind_rigid_params(self, fid.unwrap())
    self.rigid_mode = true
    check_function_body(self, fd)
    self.rigid_mode = false
    for &ps in self.pending_specs {
        const _ok = check_call_bounds(self, ps)
    }
    keep_template_types(self, fd, fid.unwrap())
    self.env.pop_scope()

    keep_ownership_diags(self, diags0)
    if self.diagnostics.len > diags0 {
        self.rigid_flagged.add(self.node_of(fd.span))
    }

    drop_pending_specs(replace(&self.pending_specs, saved_pending))
    replace(&self.results, saved_results).deinit()
    replace(&self.pending_literals, saved_literals).deinit()
    replace(&self.pending_anons, saved_anons).deinit()
    replace(&self.pending_members, saved_members).deinit()
    replace(&self.pending_fn_names, saved_fn_names).deinit()
    while self.pending_calls.len > calls0 {
        const pc = self.pending_calls.pop().unwrap()
        pc.arg_tys.deinit()
        pc.pos_exprs.deinit()
    }
    self.engine.clear_rigid()
}

// What hover shows inside a module's generic bodies: each node the rigid check typed, and the names
// and `where` bounds of the type parameters those types mention.
pub type TemplateTypes = struct {
    facts: List(TemplateTyFact)
    names: Dict(VarId, String)
    bounds: Dict(VarId, OwnedString)
}

pub fn deinit(self: move TemplateTypes) {
    self.facts.deinit()
    self.names.deinit()
    self.bounds.deinit()
}

pub type TemplateTyFact = struct {
    node: NodeId
    span: SourceSpan
    ty: Ty
}

// The innermost node of a generic body at `offset` in file `fid`, typed by its type parameters.
pub type TemplateHit = struct {
    span: SourceSpan
    ty: Ty
    names: &Dict(VarId, String)
    bounds: &Dict(VarId, OwnedString)
}

/// The innermost generic-body node at `offset` in file `fid`, as the rigid check typed it, or null
/// when no generic body covers the offset.
pub fn template_type_at(self: &Checker, fid: i32, offset: usize) TemplateHit? {
    let best: TemplateHit? = null
    let best_len = 0usize
    for e in self.template_types {
        const tt = self.template_types.get_ref(e.key).unwrap()
        for &f in tt.facts {
            const inside = f.span.file_id == fid and f.span.start <= offset
                and offset < f.span.start + f.span.length
            if !inside {
                continue
            }
            if best.is_none() or f.span.length < best_len {
                best = Some(TemplateHit {
                    span = f.span,
                    ty = f.ty,
                    names = &tt.names,
                    bounds = &tt.bounds,
                })
                best_len = f.span.length
            }
        }
    }
    return best
}

fn reset_template_types(self: &Checker, path: String) {
    const found = self.template_types.get_ref(path)
    if found.is_some() {
        let tt = found.unwrap()
        tt.facts.clear()
        tt.names.clear()
        tt.bounds.clear()
        return
    }
    const idx = self.template_type_keys.len
    self.template_type_keys.push(from_view(path))
    self.template_types.set(
        self.template_type_keys[idx].view,
        TemplateTypes { facts = list(0), names = dict(), bounds = dict() },
    )
}

// Records what the rigid check of `fd` typed, while its scratch tables and its type parameters'
// bindings are still in place.
fn keep_template_types(self: &Checker, fd: &FunctionDecl, fid: u32) {
    if self.current_module.is_none() {
        return
    }
    const found = self.template_types.get_ref(self.current_module.unwrap())
    if found.is_none() {
        return
    }
    let tt = found.unwrap()
    for e in self.results.node_types {
        const span = self.results.get_span(e.key)
        if span.is_some() {
            tt.facts.push(TemplateTyFact {
                node = e.key,
                span = span.unwrap(),
                ty = self.engine.zonk(e.value),
            })
        }
    }
    for &tp in &self.templates.get_ref(fid).unwrap().tps {
        const v = rigid_of(self, tp.name)
        if v.is_some() {
            tt.names.set(v.unwrap(), display_tp_name(self, tp.name))
        }
    }
    for &b in fd.bounds {
        const v = rigid_of(self, bound_path(self, b.param, b.path))
        if v.is_none() {
            continue
        }
        let sb = string_builder(32)
        if !render_alias_body(b.bound, &sb) {
            sb.deinit()
            continue
        }
        const prior = tt.bounds.remove(v.unwrap())
        prior match {
            Some(text) => {
                let joined = $"{text.view} + {sb.as_view()}"
                text.deinit()
                sb.deinit()
                tt.bounds.set(v.unwrap(), joined)
            }
            None => tt.bounds.set(v.unwrap(), sb.to_string())
        }
    }
}

// The rigid variable a type-parameter name is bound to in the current scope.
fn rigid_of(self: &Checker, name: String) VarId? {
    const b = self.env.lookup(name)
    if b.is_none() or !b.unwrap().is_type_param {
        return null
    }
    return ty_node(self, self.engine.resolve(self.engine.specialize(&b.unwrap().scheme))) match {
        NVar(v) => Some(v.id)
        _ => null
    }
}

// A type parameter's name as written: a contract in a parameter's type (`it: Iter`) is bound under
// its occurrence (`Iter.@40`, `Iter.@40.Item`) and shows as the contract (`Iter`, `Iter.Item`).
fn display_tp_name(self: &Checker, name: String) String {
    for i in 1..name.len {
        if name[i] != '@' {
            continue
        }
        let j = i + 1
        while j < name.len and name[j] != '.' {
            j = j + 1
        }
        const base = name[0..(i - 1)]
        return if j < name.len { intern_path(self, base, name[(j + 1)..name.len]) } else { base }
    }
    return name
}

// Whether the rigid type parameter `t` is callable by its template's bounds: a function-type bound,
// or a requirement named `op_call`.
fn rigid_callable(self: &Checker, t: Ty) bool {
    const rid = ty_node(self, self.engine.resolve(t)) match {
        NVar(v) => v.id
        _ => return true
    }
    const tv = self.rigid_tvars.get(rid)
    const atoms = self.fn_bounds.get_ref(self.rigid_fid)
    if tv.is_none() or atoms.is_none() {
        return false
    }
    for &a in atoms.unwrap() {
        const on_it = ty_node(self, self.engine.resolve(a.subject)) match {
            NVar(v) => v.id == tv.unwrap()
            _ => false
        }
        const calls = a.kind match {
            Callable => true
            Require => a.name == "op_call"
            Copyable => false
        }
        if on_it and calls {
            return true
        }
    }
    return false
}

// The template's type parameters bound to rigid variables, each copyable when its bounds say so; a
// path its bounds pinned (`Item = List(T)`) binds to the pinned type over those variables.
fn bind_rigid_params(self: &Checker, fid: u32) {
    const tps = &self.templates.get_ref(fid).unwrap().tps
    let rigid: Dict(VarId, Ty) = dict()
    defer rigid.deinit()
    for &tp in tps {
        const vid = ty_node(self, self.engine.resolve(tp.ty)) match {
            NVar(v) => v.id
            _ => continue
        }
        if rigid.contains(vid) {
            continue
        }
        const r = self.engine.fresh_rigid(copyable_in_bounds(self, fid, vid))
        rigid_var_name(self, r, display_tp_name(self, tp.name))
        rigid.set(vid, r)
        ty_node(self, r) match {
            NVar(rv) => self.rigid_tvars.set(rv.id, vid)
            _ => {}
        }
    }
    for &tp in tps {
        self.env.bind(
            tp.name,
            Binding {
                scheme = mono(self.engine.substitute_shared(self.engine.zonk(tp.ty), &rigid)),
                decl = tp.decl,
                is_const = true,
                is_type_param = true,
            },
        )
    }
}

// The registry id of a generic declaration with a template, found by its name and span.
fn template_id_of(self: &Checker, fd: &FunctionDecl) u32? {
    let vis = current_visibility(self)
    defer vis.deinit()
    let found = self.functions.lookup(fd.name, &vis) match {
        FnLookFound(c) => Some(move c)
        _ => null
    }
    if found.is_none() {
        return null
    }
    let cands = found.unwrap()
    defer cands.deinit()
    for c in cands {
        const d = c.decl_span
        const same = d.start == fd.span.start and d.length == fd.span.length
            and d.file_id == fd.span.file_id
        if same and self.templates.contains(c.id) {
            return Some(c.id)
        }
    }
    return null
}

fn rigid_var_name(self: &Checker, rigid: Ty, name: String) {
    ty_node(self, rigid) match {
        NVar(v) => self.tp_names.set(v.id, name)
        _ => {}
    }
}

// Picks a rigid check made and will never instantiate: their tables die with them.
fn drop_pending_specs(specs: move List(PendingSpec)) {
    for ps in specs.drain() {
        ps.tp_binds.deinit()
        ps.inst_params.deinit()
    }
    specs.deinit()
}

// Drops the diagnostics past `from` that an instantiation could contradict, keeping the ownership
// pass's: those hold whatever `T` turns out to be.
fn keep_ownership_diags(self: &Checker, from: usize) {
    let tail: List(Diagnostic) = list(self.diagnostics.len - from)
    while self.diagnostics.len > from {
        tail.push(self.diagnostics.pop().unwrap())
    }
    for d in tail.drain_rev() {
        if is_ownership_code(d.code) {
            self.diagnostics.push(d)
        } else {
            d.deinit()
        }
    }
    tail.deinit()
}

fn is_ownership_code(code: String) bool {
    return code == E_USE_AFTER_MOVE or code == E_COPY_NEEDS_MOVE or code == E_MOVE_NOT_LVALUE
        or code == E_ASSIGN_OVER_LIVE or code == E_PARTIAL_MOVE or code == E_CONSUMING_RECEIVER
        or code == E_NOT_OWNED or code == E_RVALUE_NO_OWNER or code == E_MOVE_AND_LEND
        or code == E_BOUND_UNSATISFIED or code == E_SLOT_NOT_REFILLED or code == E_UNBOUNDED_CALL
}

fn instantiate(
    self: &Checker,
    p: &PendingSpec,
    key: move OwnedString,
    params: move List(Ty),
    ret: Ty,
    at: SpecId? = null,
) SpecId? {
    if self.spec_depth >= MAX_SPEC_DEPTH {
        push_diag_e(
            self,
            p.span,
            E_UNINFERRED,
            from_view(
                "generic instantiation exceeds the depth limit - infinitely recursive polymorphism?",
            ),
        )
        key.deinit()
        params.deinit()
        return null
    }
    // The pick's id came from the function registry; a generic scheme without a template entry is a
    // compiler bug, not an input error.
    let template = self.templates.get_ref(p.function_id).unwrap()

    let fresh = new_specialization(
        p.function_id,
        key,
        template.decl.name,
        template.module,
        template.decl,
        params,
        ret,
        inference_results(),
    )
    let sid = 0 as SpecId
    let hints: List(SpecDep) = list(0)
    at match {
        Some(existing) => {
            install(&hints, self.specs.take_deps(existing))
            self.specs.replace_at(existing, fresh)
            sid = existing
        }
        None => {
            sid = self.specs.register(fresh)
        }
    }
    self.slot_new_specs.push(sid)
    self.spec_frames.push(SpecFrame {
        vars0 = self.engine.var_counter,
        synth0 = self.next_synth,
        lambda0 = self.next_lambda,
        child_vars = 0u32,
        child_synth = 0u32,
        child_lambda = 0u32,
        deps = list(0),
        hints = move hints,
        diags0 = self.diagnostics.len,
        calls0 = self.pending_calls.len,
    })

    // The re-check runs in the template's own context: its module for name resolution (unioned with
    // the caller chain - see `current_visibility`), a fresh overlay for the result tables, and a
    // fresh pending list so nested generic picks drain inside this frame, while the overlay is
    // still the active table set.
    let saved_results = replace(&self.results, inference_results())
    let saved_pending = replace(&self.pending_specs, list(0))
    let saved_anons = replace(&self.pending_anons, list(0))
    let saved_members = replace(&self.pending_members, list(0))
    let saved_fn_names = replace(&self.pending_fn_names, list(0))
    let saved_module = self.current_module
    self.current_module = Some(template.module)
    self.spec_callers.push(p.caller_module)
    self.spec_call_spans.push(p.span)
    self.spec_depth = self.spec_depth + 1

    // Bind each signature type param to its concrete argument; the body's `$T` / `T` occurrences
    // and `I.Item` projections resolve to these instead of minting fresh vars.
    self.env.push_scope()
    for i in 0..template.tps.len {
        const conc = atom_inst(self, template.tps[i].ty, Some(&p.tp_binds))
        self.env.bind(
            template.tps[i].name,
            Binding {
                scheme = mono(conc),
                decl = template.tps[i].decl,
                is_const = true,
                is_type_param = true,
            },
        )
    }

    const saved_skip = self.skip_ownership
    self.skip_ownership = self.rigid_flagged.contains(self.node_of(template.decl.span))
    check_function_body(self, template.decl)
    self.skip_ownership = saved_skip
    resolve_anon_literals(self)
    resolve_pending_members(self)
    resolve_fn_name_values(self)
    // The frame's own parked calls settle between two drains, as a slot's do: the first drain pins
    // what the body could not, the calls resolve against it, the second places the picks they made.
    // A parked call is work a reuse cannot replay, so the frame stays live either way.
    const frame_calls0 = self.spec_frames[self.spec_frames.len - 1].calls0
    drain_pending_specs(self, false)
    resolve_pending_members(self)
    const had_calls = self.pending_calls.len > frame_calls0
    resolve_pending_calls(self, frame_calls0)
    drain_pending_specs(self)

    self.env.pop_scope()
    self.spec_depth = self.spec_depth - 1
    let _c = self.spec_callers.pop()
    let _cs = self.spec_call_spans.pop()

    // Frame bookkeeping for a later reuse: the stream anchors, the frame's OWN burns (nested work
    // subtracted - it burns its own), the deps its drain resolved, and whether it stayed replayable
    // (a diagnostic or a parked call must be regenerated live, so either keeps the entry
    // re-checking every demand).
    let frame = self.spec_frames.pop().unwrap()
    frame.hints.deinit()
    const clean = self.diagnostics.len == frame.diags0 and !had_calls
    self.specs.set_cache_info(
        sid,
        frame.vars0,
        frame.synth0,
        frame.lambda0,
        self.engine.var_counter - frame.vars0 - frame.child_vars,
        self.next_synth - frame.synth0 - frame.child_synth,
        self.next_lambda - frame.lambda0 - frame.child_lambda,
        frame.deps,
        clean,
    )

    // The shared final zonk only walks the program tables; the overlay zonks here, while the engine
    // is live. Lambda records checked inside this instantiation zonk with it (the global closure
    // table waits for `check_all`'s final sweep - the engine outlives every overlay).
    let zonked: Dict(NodeId, Ty) = dict(self.results.node_types.len())
    for entry in self.results.node_types {
        zonked.set(entry.key, self.engine.zonk(entry.value))
    }
    self.results.replace_node_types(zonked)
    zonk_lambda_table(self)

    let overlay = replace(&self.results, saved_results)
    install(&self.pending_specs, saved_pending)
    install(&self.pending_anons, saved_anons)
    install(&self.pending_members, saved_members)
    install(&self.pending_fn_names, saved_fn_names)
    self.current_module = saved_module

    // RTTI instantiations surface program-wide, not per overlay.
    self.results.merge_instantiated(&overlay)

    // A signature that entered with callable-slot vars settled during the body check: store the
    // final shape (spec symbols mangle from it) and re-key so identical final signatures dedup. A
    // duplicate final key keeps its own entry; emission dedups by symbol.
    let sp = self.specs.get(sid)
    let fparams: List(Ty) = list(sp.concrete_params.len)
    for i in 0..sp.concrete_params.len {
        fparams.push(self.engine.zonk(sp.concrete_params[i]))
    }
    let fret = self.engine.zonk(sp.concrete_return)
    let fkey = key_for(&self.engine.interner, p.function_id, &fparams, fret)
    self.specs.set_signature(sid, fparams, fret)
    let _rk = self.specs.rekey(sid, fkey)

    self.specs.set_overlay(sid, overlay)
    return Some(sid)
}

// ─────────────────────────────────────────────────────────────────────
// Expression / statement inference - minimal subset.
//
// First slice covers: literals, identifiers, binary primitive ops on matching numeric types, calls
// (direct lookup against `FunctionRegistry`), `let` statements, `return`, block expressions. More
// advanced forms (match, lambdas, member access, generics dispatch) layer on top in follow-up
// patches.
// ─────────────────────────────────────────────────────────────────────

// `expected` is the type of the slot the value fills, when it has one: a call's overload set breaks
// an exact tie on it (overloads that differ only in their return type). Anything else ignores it.
pub fn check_expr(self: &Checker, expr: &Expr, expected: Ty? = null) Ty {
    let ty = expr.* match {
        Call(call) => check_call(self, &call, expected)
        _ => check_expr_kind(self, expr)
    }
    self.results.record_type(self.node_of(expr_span(expr)), ty)
    return ty
}

fn check_expr_kind(self: &Checker, expr: &Expr) Ty {
    return expr.* match {
        Lit(lit) => check_literal(self, &lit)
        Identifier(id) => check_identifier(self, &id)
        Block(blk) => check_block(self, &blk)
        Binary(bin) => check_binary(self, &bin)
        Call(call) => check_call(self, &call)
        If(if_expr) => check_if(self, &if_expr)
        StructLit(lit) => check_struct_lit(self, &lit)
        MemberAccess(ma) => check_member(self, &ma)
        TupleLit(t) => check_tuple_lit(self, &t)
        Cast(c) => check_cast(self, &c)
        Assignment(a) => check_assignment(self, &a)
        AddressOf(a) => check_address_of(self, &a)
        Move(m) => check_move(self, &m)
        Dereference(d) => check_deref(self, &d)
        Match(m) => check_match(self, &m)
        Index(ix) => check_index(self, &ix)
        Range(r) => check_range(self, &r)
        Unary(u) => check_unary(self, &u)
        Coalesce(co) => check_coalesce(self, &co)
        NullPropagation(np) => check_null_prop(self, &np)
        Try(tr) => check_try(self, &tr)
        InterpolatedString(is) => check_interpolation(self, &is)
        ArrayLit(al) => check_array_literal(self, &al)
        Lambda(lam) => check_lambda(self, &lam)
        Context(c) => check_context_expr(self, &c)
        ContextBind(cb) => check_context_bind(self, &cb)
        _ => self.engine.fresh_var()
    }
}

// ─────────────────────────────────────────────────────────────────────
// Runtime context (RFC-038)
// ─────────────────────────────────────────────────────────────────────

// The compiler-provided `Context` type, or null when `core.runtime` is not in the source set.
fn context_ty(self: &Checker) Ty? {
    return self.nominals.by_fqn.get(FQN_CONTEXT) match {
        Some(id) => Some(mk_nominal(self, id, list(0)))
        None => null
    }
}

// Whether `t` is `Context` or a reference to one.
fn is_context_ty(self: &Checker, t: Ty) bool {
    const id = self.nominals.by_fqn.get(FQN_CONTEXT)
    if id.is_none() {
        return false
    }
    return ty_node(self, peel_refs(self, self.engine.zonk(t))) match {
        NNominal(nn) => nn.id == id.unwrap()
        _ => false
    }
}

// Bare `context`: a copy of the current context.
fn check_context_expr(self: &Checker, c: &ContextExpr) Ty {
    return context_ty(self) match {
        Some(t) => t
        None => {
            push_diag_e(
                self,
                c.span,
                E_UNKNOWN_IDENT,
                from_view("`context` needs `core.runtime`, which declares `Context`"),
            )
            TY_ERROR
        }
    }
}

// The context field `name` names from the current module: one of its own, private or not, or a
// `pub` one of a module it sees. Reports E2150 when there is none and E2152 when two are visible.
fn resolve_context_field(self: &Checker, name: String, span: SourceSpan) CtxHit? {
    let vis = current_visibility(self)
    defer vis.deinit()
    const here = self.current_module.unwrap_or("")
    let hit: CtxHit? = null
    for entry in self.ctx_fields.entries {
        const fqn = self.ctx_fields.name(entry.key)
        const dot = last_dot(fqn)
        if short_name_of(fqn, dot) != name {
            continue
        }
        const module = module_of(fqn, dot)
        const visible = module == here or (entry.value.is_pub and vis.allows(module))
        if !visible {
            continue
        }
        if hit.is_some() {
            push_diag_e(
                self,
                span,
                E_CONTEXT_AMBIGUOUS,
                $"context field `{name}` is ambiguous: `{hit.unwrap().fqn}` and `{fqn}` are both visible",
            )
            return null
        }
        hit = Some(CtxHit { fqn = fqn, field = entry.value })
    }
    if hit.is_none() {
        push_diag_e(self, span, E_CONTEXT_UNKNOWN, $"no context field `{name}` is visible here")
    }
    return hit
}

// Record the field a use resolved to, as a result-owned FQN lowering and the LSP read.
fn record_context_target(self: &Checker, span: SourceSpan, fqn: String) {
    const stable = self.results.add_synth_string(from_view(fqn))
    self.results.record_target(self.node_of(span), ResolvedTarget.RtContextField(stable))
}

// `ctx.f` on a `Context` value: the field's declared type.
fn context_member(self: &Checker, ma: &MemberAccessExpr) Ty {
    return resolve_context_field(self, ma.member, ma.span) match {
        Some(h) => {
            record_context_target(self, ma.span, h.fqn)
            h.field.ty
        }
        None => TY_ERROR
    }
}

// `context(base?, f = v, ...) { body }`: the base is a `Context`, each named field a visible one
// typed by its declaration, and the construct's value is the body's.
fn check_context_bind(self: &Checker, cb: &ContextBindExpr) Ty {
    const cty = context_ty(self)
    let named: List(String) = list(cb.args.len)
    defer named.deinit()
    for i in 0..cb.args.len {
        cb.args[i] match {
            Positional(e) => {
                const bt = check_expr(self, e)
                if i > 0 {
                    push_diag_e(
                        self,
                        expr_span(e),
                        E_CONTEXT_BASE,
                        from_view("a rebind's base context comes first, and only once"),
                    )
                } else if cty.is_some() {
                    unify_expected(self, bt, cty.unwrap(), E_TYPE_MISMATCH, expr_span(e))
                }
            }
            Named(n) => check_context_override(self, &n, &named)
        }
    }
    return check_block(self, cb.body)
}

fn check_context_override(self: &Checker, n: &NamedCallArgument, named: &List(String)) {
    if contains_view(named, n.name) {
        push_diag_e(
            self,
            n.span,
            E_CONTEXT_TWICE,
            $"context field `{n.name}` is named twice in one rebind",
        )
    }
    named.push(n.name)
    const hit = resolve_context_field(self, n.name, n.span)
    if hit.is_none() {
        const _v = check_expr(self, n.value)
        return
    }
    const h = hit.unwrap()
    record_context_target(self, n.span, h.fqn)
    const vt = check_expr(self, n.value, Some(h.field.ty))
    unify_expected(self, vt, h.field.ty, E_TYPE_MISMATCH, expr_span(n.value))
}

// Whether `e` is storage inside the current context: `context` itself, or a field reached from it
// without crossing a reference.
fn in_current_context(self: &Checker, e: &Expr) bool {
    return e.* match {
        Context(_) => true
        MemberAccess(ma) => !receiver_is_ref(self, ma.receiver)
            and in_current_context(self, ma.receiver)
        Index(ix) => !receiver_is_ref(self, ix.receiver) and in_current_context(self, ix.receiver)
        _ => false
    }
}

fn receiver_is_ref(self: &Checker, e: &Expr) bool {
    return self.results.get_type(self.node_of(expr_span(e))) match {
        Some(t) => ty_node(self, self.engine.zonk(t)) match { NRef(_) => true, _ => false }
        None => false
    }
}

// `[a, b, c]` and `[v; N]`. Elements unify to one type; the node types as `[T; len]`. A repeat
// count must be a plain integer literal - the only form the corpus writes - any other count
// expression leaves the node untyped (fresh var), the pre-M10 behavior for unsizable shapes.
fn check_array_literal(self: &Checker, al: &ArrayLiteralExpr) Ty {
    return al.kind match {
        Elements(es) => {
            if es.len == 0 {
                return self.engine.mk_array(self.engine.fresh_var(), 0)
            }
            let elem = check_expr(self, &es[0])
            for i in 1..es.len {
                let t = check_expr(self, &es[i])
                unify_expected(self, t, elem, E_TYPE_MISMATCH, expr_span(&es[i]))
            }
            self.engine.mk_array(elem, es.len)
        }
        Repeat(r) => {
            let elem = check_expr(self, r.value)
            // `[v; n]` - the repeat count is a `usize`, so a non-numeric count is a plain type
            // mismatch at the count expression.
            const ct = check_expr(self, r.count)
            unify_expected(self, ct, ty_usize(), E_TYPE_MISMATCH, expr_span(r.count))
            let n = literal_count_of(r.count)
            n match {
                Some(len) => self.engine.mk_array(elem, len)
                None => self.engine.fresh_var()
            }
        }
    }
}

// The compile-time value of a repeat count written as a plain decimal integer literal; null for any
// other expression.
fn literal_count_of(e: &Expr) usize? {
    let lit = e.* match { Lit(l) => l, _ => return null }
    let il = lit.value match { Int(v) => v, _ => return null }
    return parse_decimal(il.text)
}

// Plain decimal digits (underscore separators allowed) to a usize; null for anything else.
fn parse_decimal(s: String) usize? {
    if s.len == 0 {
        return null
    }
    let n: usize = 0
    for i in 0..s.len {
        const c = s[i]
        if c == '_' {
            continue
        }
        if c < '0' or c > '9' {
            return null
        }
        n = n * 10 + ((c as usize) - 48)
    }
    return Some(n)
}

// String interpolation (RFC-004): desugar to StringBuilder calls, exactly as the reference checker
// does - the feature is stdlib-dependent by design. The desugar is synthesized as real AST and
// checked through the ordinary machinery, so overload resolution picks each `append` (and the
// format-spec fallback), the picks land on the synthetic nodes' ids, and the result type is
// whatever `to_string` returns - resolved, not assumed. The block is stored in `results.desugars`
// keyed by the interpolation node; lowering replays it instead of the original node.
//
//   $"a{x}b"       => { let __interp_sb_N = string_builder(0)
//                       defer __interp_sb_N.deinit()
//                       __interp_sb_N.append("a")
//                       __interp_sb_N.append(x)
//                       __interp_sb_N.append("b")
//                       __interp_sb_N.to_string() }
//   $sb"a{x}"      => { sb.append("a") sb.append(x) }        (void)
//
// The deferred deinit is a no-op on the happy path (`to_string` transfers ownership and zeroes the
// builder) and frees the buffer when a hole's expression escapes early (`$"{f()?}"`).
//
// `$(…)` constructor args map onto `string_builder(capacity)`
// at FULL arity - the defaults are spelled out as `0` / `null`, so the desugared call never leans
// on defaulted-argument materialization, which lowering does not do yet. A lone `&alloc` argument
// routes to the allocator slot wrapped in `Some(...)` (no implicit T -> Option(T)).
//
fn check_interpolation(self: &Checker, interp: &InterpolatedStringExpr) Ty {
    return interp.target match {
        NewString(args) => check_interp_owned(self, interp, args)
        IntoBuilder(t) => check_interp_into(self, interp, t)
    }
}

fn check_interp_owned(self: &Checker, interp: &InterpolatedStringExpr, given: Expr[]) Ty {
    // The synthesized AST stores the name as a view; the buffer parks with the result tables, which
    // the desugar shares a lifetime with.
    const name = self.results.add_synth_string(fresh_builder_name(self))
    let stmts: List(Stmt) = list(interp.parts.len + 1)

    const ctor = synth_free_call(self, "string_builder", builder_ctor_args(self, given))
    const let_span = synth_span(self)
    stmts.push(Stmt.Let(LetStmt {
        span = let_span,
        is_const = false,
        name = name,
        name_span = let_span,
        type_annotation = null,
        init = Some(self.synth_box(ctor)),
    }))
    let no_args: List(CallArgument) = list(0)
    stmts.push(Stmt.Defer(DeferStmt {
        span = synth_span(self),
        expr = self.synth_box(synth_method_call(self, name, "deinit", no_args)),
    }))
    push_append_stmts(self, &stmts, name, interp)

    let empty_args: List(CallArgument) = list(0)
    const done = synth_method_call(self, name, "to_string", empty_args)
    let block = box(
        context.allocator,
        BlockExpr {
            span = synth_span(self),
            stmts = frozen(stmts),
            trailing = Some(synth_box(self, done)),
        },
    )
    const ty = check_block(self, block)
    self.results.record_desugar(self.node_of(interp.span), block)
    return ty
}

// `$sb"…"` - append each part into the existing builder; void. The
// parser only produces an identifier target; anything else is visited so errors report, but gets no
// desugar (lowering refuses the node).
fn check_interp_into(self: &Checker, interp: &InterpolatedStringExpr, target: &Expr) Ty {
    let tname = ""
    target.* match {
        Identifier(ide) => { tname = ide.name }
        _ => {}
    }
    if tname.len == 0 {
        let _t = check_expr(self, target)
        for i in 0..interp.parts.len {
            interp.parts[i] match {
                Hole(h) => { let _h = check_expr(self, h.expr) }
                Text(_) => {}
            }
        }
        return TY_VOID
    }

    let stmts: List(Stmt) = list(interp.parts.len)
    push_append_stmts(self, &stmts, tname, interp)
    let block = box(
        context.allocator,
        BlockExpr { span = synth_span(self), stmts = frozen(stmts), trailing = null },
    )
    const ty = check_block(self, block)
    self.results.record_desugar(self.node_of(interp.span), block)
    return ty
}

// One `NAME.append(part)` statement per non-empty part. A hole with a format spec passes it as a
// trailing String argument - overload resolution finds the spec-taking `append`.
fn push_append_stmts(
    self: &Checker,
    stmts: &List(Stmt),
    name: String,
    interp: &InterpolatedStringExpr,
) {
    for i in 0..interp.parts.len {
        interp.parts[i] match {
            Text(t) => {
                if t.len > 0 {
                    let args: List(CallArgument) = list(1)
                    const lit = synth_string_lit(self, segment_literal_text(self, t))
                    args.push(CallArgument.Positional(synth_box(self, lit)))
                    push_expr_stmt(self, stmts, synth_method_call(self, name, "append", args))
                }
            }
            Hole(h) => {
                const spec_lit = h.format match {
                    Some(spec) => synth_string_lit(
                        self,
                        self.results.add_synth_string(escape_backslashes(self, spec)),
                    )
                    None => synth_string_lit(self, "")
                }
                if hole_is_place(h.expr) {
                    push_expr_stmt(self, stmts, synth_hole_format(self, name, h.expr, spec_lit))
                } else {
                    let args: List(CallArgument) = list(2)
                    args.push(CallArgument.Positional(h.expr))
                    args.push(CallArgument.Positional(synth_box(self, spec_lit)))
                    push_expr_stmt(self, stmts, synth_method_call(self, name, "append", args))
                }
            }
        }
    }
}

// Whether a hole names a place rather than producing a value. A place is read: `$"{s}"` must leave
// `s` the caller's, while a temporary has no other owner and goes to the consuming `append`.
fn hole_is_place(e: &Expr) bool {
    return e.* match {
        Identifier(_) => true
        MemberAccess(_) => true
        Index(_) => true
        Dereference(_) => true
        _ => false
    }
}

// `place.format(NAME.writer(), spec)` - the read form of an append.
fn synth_hole_format(self: &Checker, name: String, place: &Expr, spec_lit: move Expr) Expr {
    let wargs: List(CallArgument) = list(0)
    let args: List(CallArgument) = list(2)
    args.push(CallArgument.Positional(synth_box(
        self,
        synth_method_call(self, name, "writer", wargs),
    )))
    args.push(CallArgument.Positional(synth_box(self, spec_lit)))
    const ma = Expr.MemberAccess(MemberAccessExpr {
        span = synth_span(self),
        receiver = place,
        member = "format",
    })
    return Expr.Call(CallExpr {
        span = synth_span(self),
        callee = synth_box(self, ma),
        args = frozen(args),
    })
}

fn push_expr_stmt(self: &Checker, stmts: &List(Stmt), e: move Expr) {
    stmts.push(Stmt.Expression(ExpressionStmt {
        span = synth_span(self),
        expr = self.synth_box(e),
    }))
}

// `$(…)` args onto `string_builder(capacity)`, full arity.
fn builder_ctor_args(self: &Checker, given: Expr[]) List(CallArgument) {
    // The arguments stay the interpolation's: each is shared into the synthesized call as the arena
    // node it already is.
    let cap: &Expr? = null
    let alloc_arg: &Expr? = null
    if given.len >= 1 {
        const first = &given[0]
        const first_is_addr = first.* match { AddressOf(_) => true, _ => false }
        if given.len == 1 and first_is_addr {
            alloc_arg = Some(first)
        } else {
            cap = Some(first)
        }
    }
    if given.len >= 2 {
        alloc_arg = Some(&given[1])
    }

    let out: List(CallArgument) = list(2)
    const cap_e = cap match {
        Some(e) => e
        None => synth_box(self, synth_int_lit(self, "0"))
    }
    out.push(CallArgument.Positional(cap_e))
    // No allocator given leaves the parameter's default: the context's.
    alloc_arg match {
        Some(e) => out.push(CallArgument.Positional(e))
        None => {}
    }
    return out
}

// ── desugar synthesis helpers ────────────────────────────────────────

// The id for `span`, recording the span in the result's inverse table on the way through. Every id
// the checker mints comes from here, so `TypeCheckResult.spans` maps each one back to the span it
// names.
fn node_of(self: &Checker, span: SourceSpan) NodeId {
    const id = node_id_of(span)
    self.results.record_span(id, span)
    if self.sig_capture {
        self.sig_nodes.push(SigNodeFact { node = id, span = span, ty = null })
    }
    return id
}

// A span no real AST node carries: `file_id = -2` marks checker- synthesized nodes, and the
// monotonic `start` keeps every synthetic node id unique (node ids pack (start, length, file_id) -
// node_id.f). Diagnostics raised on a synthetic node render without a real source location; hole
// expressions keep their own real spans, so user errors still point at user code.
fn synth_span(self: &Checker) SourceSpan {
    const n = self.next_synth
    self.next_synth = n + 1
    return SourceSpan { file_id = -2, start = n as usize, length = 0 }
}

// Synthesized nodes live as long as the check result - allocated on the global allocator and
// deliberately leaked with it.
fn synth_box(self: &Checker, e: move Expr) &Expr {
    return box(context.allocator, e)
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
fn synth_method_call(
    self: &Checker,
    recv_name: String,
    method: String,
    args: move List(CallArgument),
) Expr {
    const ma = Expr.MemberAccess(MemberAccessExpr {
        span = synth_span(self),
        receiver = synth_box(self, synth_ident(self, recv_name)),
        member = method,
    })
    return Expr.Call(CallExpr {
        span = synth_span(self),
        callee = synth_box(self, ma),
        args = frozen(args),
    })
}

fn synth_free_call(self: &Checker, name: String, args: move List(CallArgument)) Expr {
    return Expr.Call(CallExpr {
        span = synth_span(self),
        callee = synth_box(self, synth_ident(self, name)),
        args = frozen(args),
    })
}

fn fresh_builder_name(self: &Checker) OwnedString {
    const n = self.next_synth
    self.next_synth = n + 1
    let sb = string_builder(20)
    defer sb.deinit()
    sb.append("__interp_sb_")
    sb.append(n)
    return sb.to_string()
}

// A segment's bytes as string-literal text, such that lowering's string-literal decode yields
// exactly the segment's decoded bytes. Segments share the string escape vocabulary and add `{{` /
// `}}` doubling - so brace-free raw text passes through untouched, and braced text is decoded
// (decode_interp_segment) then re-escaped.
fn segment_literal_text(self: &Checker, raw: String) String {
    let has_brace = false
    for i in 0..raw.len {
        if raw[i] == '{' or raw[i] == '}' {
            has_brace = true
        }
    }
    if !has_brace {
        return raw
    }
    const decoded_opt = decode_interp_segment(raw)
    // Malformed escape - the lexer already reported it; keep the raw text.
    if decoded_opt.is_none() {
        return raw
    }
    let decoded = decoded_opt.unwrap()
    const out = self.results.add_synth_string(escape_backslashes(self, decoded.view))
    decoded.deinit()
    return out
}

// Double every backslash so a later string-literal decode is the identity on the remaining bytes.
// Always hands ownership out - a clean input copies - so the caller decides where the buffer lives.
fn escape_backslashes(self: &Checker, s: String) OwnedString {
    let has = false
    for i in 0..s.len {
        if s[i] == '\\' {
            has = true
        }
    }
    if !has {
        return from_view(s)
    }
    let sb = string_builder(s.len + 4)
    defer sb.deinit()
    for i in 0..s.len {
        if s[i] == '\\' {
            sb.append_byte('\\')
        }
        sb.append_byte(s[i])
    }
    return sb.to_string()
}

// `scrutinee match { pat => body, ... }`. Each arm's pattern is checked against the scrutinee's
// type, its bindings live for that arm only, and every arm body unifies to one result type.
//
// Exhaustiveness is not checked here.
fn check_match(self: &Checker, m: &MatchExpr) Ty {
    let scrutinee = check_expr(self, m.scrutinee)
    // `Never` is the identity of the arm join - it takes the other side - so the first arm sets the
    // type and a match whose every arm diverges stays `Never`. That is the honest answer: such a
    // match has no value to consume, and `Never` unifies with whatever the context wants.
    let result = TY_NEVER
    for &arm in m.arms {
        self.env.push_scope()
        check_pattern(self, arm.pattern, scrutinee)
        arm.guard match {
            Some(g) => { let _g = check_expr(self, g) }
            None => {}
        }
        let body_ty = check_expr(self, arm.body)
        result = join_types(self, result, body_ty, E_ARM_MISMATCH, arm.span)
        self.env.pop_scope()
    }
    check_match_coverage(self, m, scrutinee)
    return result
}

// E2030 / E2031: an enum scrutinee must have every variant covered (or a catch-all arm); a non-enum
// scrutinee cannot be matched with variant patterns at all. Guarded arms never count as coverage -
// the guard may fail. Mirrors the reference's ad-hoc exhaustiveness pass.
fn check_match_coverage(self: &Checker, m: &MatchExpr, scrutinee: Ty) {
    let peeled = peel_refs(self, scrutinee)
    let nid = ty_node(self, peeled) match {
        NNominal(nn) => Some(nn.id)
        _ => null
    }
    const ed: &EnumDef? = if nid.is_some() {
        self.nominals.get(nid.unwrap()).* match {
            NomEnum(e) => Some(&e)
            _ => null
        }
    } else {
        null
    }
    if ed.is_none() {
        // A still-open scrutinee may yet become an enum; anything else concrete never will (E2030).
        let open = self.engine.is_var(peeled) or peeled.is_error()
        if !open and match_names_variant(self, m) {
            push_diag_e(
                self,
                m.span,
                E_MATCH_NON_ENUM,
                from_view("cannot match variant patterns on a non-enum type"),
            )
        }
        return
    }
    let e = ed.unwrap()

    let covered: List(String) = list(e.variants.len)
    defer covered.deinit()
    for &arm in m.arms {
        if arm.guard.is_some() {
            continue
        }
        if pattern_is_catch_all(self, arm.pattern, e) {
            return
        }
        collect_covered(self, arm.pattern, e, &covered)
    }
    let missing: List(String) = list(0)
    defer missing.deinit()
    for i in 0..e.variants.len {
        if !covered.contains(e.variants[i].name) {
            missing.push(e.variants[i].name)
        }
    }
    if missing.len > 0 {
        push_diag_e(
            self,
            m.span,
            E_MATCH_NON_EXHAUSTIVE,
            $"non-exhaustive match: missing variant `{missing[0]}`",
        )
    }
}

// A bare identifier binds (and so matches everything) UNLESS it names one of the scrutinee enum's
// variants - the same rule `check_variable_pattern` applies when binding.
fn pattern_is_catch_all(self: &Checker, pat: &Pattern, e: &EnumDef) bool {
    return pat.* match {
        Wildcard(_) => true
        Variable(v) => !variant_named(&e.variants, v.name)
        Or(o) => any_catch_all(self, o.alternatives, e)
        _ => false
    }
}

fn any_catch_all(self: &Checker, alts: Pattern[], e: &EnumDef) bool {
    for i in 0..alts.len {
        if pattern_is_catch_all(self, &alts[i], e) {
            return true
        }
    }
    return false
}

fn collect_covered(self: &Checker, pat: &Pattern, e: &EnumDef, out: &List(String)) {
    pat.* match {
        EnumVariant(ev) => out.push(ev.name)
        Variable(v) => {
            if variant_named(&e.variants, v.name) {
                out.push(v.name)
            }
        }
        Or(o) => {
            for i in 0..o.alternatives.len {
                collect_covered(self, &o.alternatives[i], e, out)
            }
        }
        _ => {}
    }
}

// Whether any arm tries to match a VARIANT: a payload-carrying or qualified variant pattern, or a
// bare identifier that names a type in
// scope (`Point => …` over a struct scrutinee - the projector cannot
// tell that from a binding, so the name decides).
fn match_names_variant(self: &Checker, m: &MatchExpr) bool {
    let vis = fn_visibility(self)
    defer vis.deinit()
    for &arm in m.arms {
        arm.pattern match {
            EnumVariant(_) => return true
            Variable(v) => {
                let known = self.nominals.lookup(v.name, &vis) match {
                    NomLookFound(_) => true
                    _ => false
                }
                if known {
                    return true
                }
            }
            _ => {}
        }
    }
    return false
}

// Check `pat` against `expected`, binding the variables it introduces into the current scope. Every
// sub-pattern is walked even when the shape can't be resolved, so a binding always exists -
// unconstrained beats absent, which would surface later as a bogus `unknown identifier`.
fn check_pattern(self: &Checker, pat: &Pattern, expected: Ty, is_sub: bool = false) {
    // Lowering reads every sub-pattern's type off its own node (`bind_variant_payload` ->
    // `node_ty(pattern_span(sub))`), so record it for ALL pattern forms, not just the variable ones
    // `bind_pattern_var` covers. Without this a tuple sub-pattern (`Ok((v, n))`) fell back to
    // lowering's `i32` default, `tuple_pattern_member` refused to see a tuple, and both bindings
    // were silently dropped - surfacing much later as "unbound name read". Kind-specific code below
    // may refine it.
    self.results.record_type(self.node_of(pattern_span(pat)), expected)
    pat.* match {
        Wildcard(_) => {}
        Variable(v) => check_variable_pattern(self, &v, expected, is_sub)
        Literal(l) => {
            let lt = literal_value_ty(self, l.value)
            unify_expected(self, lt, expected, E_TYPE_MISMATCH, l.span)
            // A String pattern is an `op_eq(String, String)` call at match time - record the pick
            // on the pattern node so lowering can dispatch it (M11), like binary `==` does.
            let is_str = l.value match { String(_) => true, _ => false }
            if is_str {
                let pick = operator_pick_2(
                    self,
                    "op_eq",
                    self.engine.resolve(expected),
                    self.engine.resolve(lt),
                    l.span,
                )
                if pick.is_some() {
                    let p = pick.unwrap()
                    self.results.record_operator(
                        self.node_of(l.span),
                        ResolvedOperator {
                            function_id = p.id,
                            negate_result = false,
                            cmp_derived_op = null,
                            is_ref_form = false,
                            spec_id = null,
                            lhs_hops = 0u32,
                            rhs_hops = 0u32,
                        },
                    )
                    note_pending(self, l.span, true, &p)
                }
            }
        }
        EnumVariant(ev) => check_variant_pattern(self, &ev, expected)
        Or(o) => check_or_pattern(self, &o, expected)
        Range(r) => {
            let bound = check_range_bounds(self, &r)
            unify_expected(self, bound, expected, E_TYPE_MISMATCH, r.span)
        }
        Struct(s) => check_struct_pattern(self, &s, expected)
        Tuple(t) => check_tuple_pattern(self, &t, expected)
        // Projection reported it (E2115) and lowering refuses the match, so there is nothing to
        // check and nothing to bind.
        Error(_) => {}
    }
}

fn check_or_pattern(self: &Checker, o: &OrPattern, expected: Ty) {
    for i in 0..o.alternatives.len {
        check_pattern(self, &o.alternatives[i], expected)
    }
}

// `Point { x = 0, y }` - each named field's sub-pattern is checked against that field's
// (substituted) type, so a literal sub-pattern pins and a shorthand binding gets the real type
// instead of a free var. The pattern's own type name is unified with the scrutinee, which is what
// makes `p match { Point { … } }` reject a non-Point scrutinee.
fn check_struct_pattern(self: &Checker, s: &StructPattern, expected: Ty) {
    const declared = resolve_type_expr(self, s.type_expr)
    unify_expected(self, declared, expected, E_TYPE_MISMATCH, s.span)
    for &f in s.fields {
        let fty = struct_field_lookup(self, expected, f.name)
        if fty.is_none() {
            push_diag_e(self, f.span, E_FIELD_NOT_FOUND, $"no field `{f.name}` on this type")
        }
        if fty.is_some() {
            record_init_ref(self, expected, f.name, f.span)
        }
        const t = fty match {
            Some(x) => x
            None => self.engine.fresh_var()
        }
        f.binding match {
            Some(p) => check_pattern(self, p, t, true)
            None => bind_pattern_var(self, f.name, t, f.span)
        }
    }
}

// `(a, b)` - each element against the scrutinee tuple's element type.
fn check_tuple_pattern(self: &Checker, t: &TuplePattern, expected: Ty) {
    let elems = ty_node(self, self.engine.resolve(expected)) match {
        NTuple(es) => Some(es)
        _ => null
    }
    if elems.is_none() {
        bind_unconstrained(self, t.elements)
        return
    }
    let es = elems.unwrap()
    if es.len != t.elements.len {
        push_diag_e(
            self,
            t.span,
            E_MATCH_ARITY,
            $"tuple pattern has {t.elements.len} element(s), the value has {es.len}",
        )
        bind_unconstrained(self, t.elements)
        return
    }
    for i in 0..t.elements.len {
        check_pattern(self, &t.elements[i], self.engine.interner.child_at(es, i), true)
    }
}

fn bind_unconstrained(self: &Checker, pats: Pattern[]) {
    for i in 0..pats.len {
        check_pattern(self, &pats[i], self.engine.fresh_var())
    }
}

// `Some(x)` / `Color.Red` in pattern position. Resolves the variant against the scrutinee's enum,
// binds each payload sub-pattern to its declared type, and records `RtEnumVariant` on the pattern
// node so lowering can read the variant index without re-resolving - the same seam calls use for
// `RtFunction`.
fn check_variant_pattern(self: &Checker, ev: &EnumVariantPattern, expected: Ty) {
    // Matching through a reference auto-dereferences (`lst match { Cons(_, t) => … }`
    // where `lst: &List(T)`), so the enum is found by peeling first - without this the payload
    // bindings fall back to free vars and any generic call on them becomes un-inferable.
    let peeled = peel_refs(self, expected)
    let nr = ty_node(self, peeled) match {
        NNominal(n) => Some(n)
        _ => null
    }
    if nr.is_none() {
        bind_unconstrained(self, ev.payloads)
        return
    }
    let n = nr.unwrap()

    let ed = self.nominals.get(n.id).* match {
        NomEnum(e) => Some(move e)
        _ => null
    }
    if ed.is_none() {
        bind_unconstrained(self, ev.payloads)
        return
    }
    let e = ed.unwrap()

    let vnum = 0u32
    let found = false
    for i in 0..e.variants.len {
        if !found and e.variants[i].name == ev.name {
            vnum = i as u32
            found = true
        }
    }
    if !found {
        push_diag_e(
            self,
            ev.span,
            E_UNKNOWN_VARIANT,
            $"unknown variant `{ev.name}` for type `{e.fqn}`",
        )
        bind_unconstrained(self, ev.payloads)
        return
    }
    self.results.record_target(self.node_of(ev.span), ResolvedTarget.RtEnumVariant(n.id, vnum))
    if ev.qualifier.is_some() {
        record_nominal_ref(self, head_span(ev.span, ev.qualifier.unwrap().len), n.id)
    }

    let payloads = &e.variants[vnum as usize].payloads
    if payloads.len != ev.payloads.len {
        push_diag_e(
            self,
            ev.span,
            E_MATCH_ARITY,
            $"variant `{ev.name}` expects {payloads.len} binding(s), got {ev.payloads.len}",
        )
        bind_unconstrained(self, ev.payloads)
        return
    }

    // Payload types are written against the enum's own type params; the scrutinee's type arguments
    // give them concrete meaning.
    let sub = member_subst(self, self.engine.zonk(peeled), &e.type_params, &e.assoc_params, n.args)
    for i in 0..payloads.len {
        let pty = self.engine.substitute_shared(payloads[i], &sub)
        check_pattern(self, &ev.payloads[i], pty, true)
    }
    sub.deinit()
}

// A bare identifier in pattern position is either a binding or a payload-less enum variant (`None`,
// `Red`). Only scope tells them apart: if the scrutinee is an enum with a nullary variant of that
// name, the identifier names the variant. Otherwise it binds.
//
// Getting this backwards is silent: a variant read as a binding is irrefutable, so `c match { Red
// => 1, Green => 2 }` would always take the first arm. Lowering reads the decision back off the
// node as `RtEnumVariant`, so it never has to re-derive it.
fn check_variable_pattern(self: &Checker, v: &VariablePattern, expected: Ty, is_sub: bool = false) {
    let peeled = peel_refs(self, expected)
    let nr = ty_node(self, peeled) match {
        NNominal(n) => Some(n)
        _ => null
    }
    if nr.is_some() {
        let n = nr.unwrap()
        let idx = nullary_variant_index(self, n.id, v.name)
        if idx.is_some() {
            self.results.record_target(
                self.node_of(v.span),
                ResolvedTarget.RtEnumVariant(n.id, idx.unwrap()),
            )
            return
        }
        // A TOP-LEVEL bare identifier over an enum scrutinee names a variant, not a binding - use
        // `_` or `else` to catch the rest (E2037, reference parity). Inside a variant's payload the
        // same shape IS a binding, which is why `is_sub` exists.
        if !is_sub {
            let ed = self.nominals.get(n.id).* match {
                NomEnum(e) => Some(&e)
                _ => null
            }
            if ed.is_some() {
                const def = ed.unwrap()
                if !variant_named(&def.variants, v.name) {
                    push_diag_e(
                        self,
                        v.span,
                        E_UNKNOWN_VARIANT,
                        $"unknown variant `{v.name}` for type `{def.fqn}`",
                    )
                    return
                }
            }
        }
    }
    bind_pattern_var(self, v.name, expected, v.span)
}

// The index of `name` among `id`'s variants, when that variant carries no payload. Null when `id`
// is not an enum or has no such variant.
fn nullary_variant_index(self: &Checker, id: NominalId, name: String) u32? {
    let ed = self.nominals.get(id).* match {
        NomEnum(e) => Some(move e)
        _ => null
    }
    if ed.is_none() {
        return null
    }
    let e = ed.unwrap()
    for i in 0..e.variants.len {
        let vd = &e.variants[i]
        if vd.name == name and vd.payloads.len == 0 {
            return Some(i as u32)
        }
    }
    return null
}

fn bind_pattern_var(self: &Checker, name: String, ty: Ty, span: SourceSpan) {
    self.env.bind(
        name,
        Binding {
            scheme = mono(ty),
            decl = self.node_of(span),
            is_const = true,
            is_type_param = false,
        },
    )
    // Lowering reads the binding's type off the pattern node.
    self.results.record_type(self.node_of(span), ty)
}

// `lhs = rhs` - an expression that yields no value. The right side must fit the left's type, so
// lowering can pick a store width from the destination.
//
// ponytail: a non-place left side (`f() = 1`) is still not rejected here; lowering refuses to emit
// the function instead of writing somewhere arbitrary, so the failure is loud but the diagnostic is
// not precise.
fn check_assignment(self: &Checker, a: &AssignmentExpr) Ty {
    // `base[key] = value` may dispatch to a user `op_set_index` (Dict sugar, RFC-021's expander
    // uses it). Places win - builtin bases and `op_index_ref` picks keep the ordinary place-store
    // path.
    const set_dispatched = a.lhs.* match {
        Index(ix) => try_set_index_assignment(self, a, &ix)
        _ => false
    }
    if set_dispatched {
        return TY_VOID
    }

    // `const x = 10; x = 20` - a const binding is write-once (E2038).
    a.lhs.* match {
        Identifier(id) => {
            let b = self.env.lookup(id.name)
            b match {
                Some(bd) => {
                    if bd.is_const {
                        push_diag_e(
                            self,
                            a.span,
                            E_CONST_ASSIGN,
                            $"cannot assign to `{id.name}`: it is declared `const`",
                        )
                    }
                }
                None => {}
            }
        }
        _ => {}
    }

    let lhs = check_expr(self, a.lhs)
    let rhs = check_expr(self, a.rhs, Some(lhs))
    unify_expected(self, rhs, lhs, E_TYPE_MISMATCH, a.span)
    if in_current_context(self, a.lhs) {
        push_diag_e(
            self,
            a.span,
            E_CONTEXT_PLACE,
            from_view("the current context is never mutated - rebind it: `context(f = v) { ... }`"),
        )
        return TY_VOID
    }
    // Scoped mutability (spec 8): a struct's fields are writable only in the module that declares
    // it - the defining module owns the type's invariants. Reads stay unrestricted, and tuples are
    // exempt (no defining module).
    a.lhs.* match {
        MemberAccess(ma) => check_scoped_mutability(self, &ma, a.span)
        _ => {}
    }
    return TY_VOID
}

fn check_scoped_mutability(self: &Checker, ma: &MemberAccessExpr, span: SourceSpan) {
    field_owner_elsewhere(self, ma) match {
        Some(o) => push_diag_e(
            self,
            span,
            E_SCOPED_MUTABILITY,
            $"cannot assign to field `{ma.member}` of `{o.fqn}` from outside its defining module `{o.module}` (scoped mutability)",
        )
        None => {}
    }
}

// The struct a field access reaches into, when reaching into it from here is denied. Null when it
// is allowed: the receiver is not a struct, the struct is synthesized (closure envs and anonymous
// records have no defining module and are writable where they are built), or the current module IS
// the defining one.
type FieldOwner = struct {
    fqn: String
    module: String
}

fn field_owner_elsewhere(self: &Checker, ma: &MemberAccessExpr) FieldOwner? {
    if self.current_module.is_none() {
        return null
    }
    let here = self.current_module.unwrap()
    let recv = self.results.get_type(self.node_of(expr_span(ma.receiver)))
    if recv.is_none() {
        return null
    }
    let peeled = peel_refs(self, recv.unwrap())
    let nid_opt = ty_node(self, peeled) match {
        NNominal(nn) => Some(nn.id)
        _ => null
    }
    if nid_opt.is_none() {
        return null
    }
    let sd_opt = self.nominals.get(nid_opt.unwrap()).* match {
        NomStruct(s) => Some(move s)
        _ => null
    }
    if sd_opt.is_none() {
        return null
    }
    let sd = sd_opt.unwrap()
    if sd.module.len == 0 or sd.module == here {
        return null
    }
    return Some(FieldOwner { fqn = sd.fqn, module = sd.module })
}

// Probe `op_set_index(&Self, K, V)` (then the value-self shape) for an index-target assignment.
// Returns true when the assignment resolved and was recorded as an operator on the ASSIGNMENT node;
// false falls back to the place path (which re-checks the subtrees - the engine records are
// idempotent). Never reports: the place path owns the diagnostics.
fn is_slice_nominal(self: &Checker, id: NominalId) bool {
    return self.nominals.get(id).* match {
        NomStruct(st) => st.fqn == FQN_SLICE or st.fqn == FQN_STRING
        _ => false
    }
}

fn try_set_index_assignment(self: &Checker, a: &AssignmentExpr, ix: &IndexExpr) bool {
    const base = check_expr(self, ix.receiver)
    const rbase = self.engine.resolve(base)
    // Slices are `Nominal(core.slice.Slice)`; user nominals are what op_set_index targets, so only
    // non-Slice nominals proceed.
    const builtin = ty_node(self, rbase) match {
        NArray(_) => true
        NPrim(_) => true
        NVar(_) => true
        NError => true
        NNominal(n0) => is_slice_nominal(self, n0.id)
        NRef(inner) => ty_node(self, inner) match {
            NArray(_) => true
            NPrim(_) => true
            NNominal(n1) => is_slice_nominal(self, n1.id)
            _ => false
        }
        _ => true
    }
    if builtin {
        return false
    }
    const key = check_expr(self, ix.index)
    // A declared ref-form place wins over op_set_index - reached the same way `check_index` will
    // reach it (through `op_deref` included), so the key's type commits here and the place path
    // re-checks a settled index rather than minting a second literal var.
    let key_only: List(Ty) = list(1)
    key_only.push(key)
    const has_place = receiver_pick(self, "op_index_ref", base, &key_only, ix.span, ix.span)
    key_only.deinit()
    if has_place.is_some() {
        return false
    }

    const value = check_expr(self, a.rhs)
    // Resolved as the method call it desugars to - `&Self`, value self, or through `op_deref` -
    // with the hop chain recorded on the assignment node beside the operator.
    let extra: List(Ty) = list(2)
    extra.push(key)
    extra.push(value)
    let pick = receiver_pick(self, "op_set_index", base, &extra, a.span, a.span)
    extra.deinit()
    if pick.is_none() {
        return false
    }
    const p = pick.unwrap()
    self.results.record_operator(
        self.node_of(a.span),
        ResolvedOperator {
            function_id = p.id,
            negate_result = false,
            cmp_derived_op = null,
            is_ref_form = true,
            spec_id = null,
            lhs_hops = 0u32,
            rhs_hops = 0u32,
        },
    )
    note_pending(self, a.span, true, &p)
    return true
}

// `move operand` yields the operand's own type - the keyword is transparent to inference, so a
// `move` in any position type-checks exactly as the bare operand does. Two rules are local to the
// node and settled here; which sites REQUIRE a `move` and which binding one kills are the ownership
// pass's business (RFC-028).
fn check_move(self: &Checker, m: &MoveExpr) Ty {
    const inner = check_expr(self, m.operand)
    if !is_move_operand(m.operand) {
        push_diag_e(
            self,
            m.span,
            E_MOVE_NOT_LVALUE,
            from_view(
                "`move` needs a place to take from; an expression with no storage of its own leaves nothing behind to mark moved",
            ),
        )
        return inner
    }
    // Moving a field takes the same rights as writing one: the declaring module owns the type's
    // invariants, so a consuming library cannot take a resource out of someone else's value.
    m.operand.* match {
        MemberAccess(ma) => {
            field_owner_elsewhere(self, &ma) match {
                Some(o) => push_diag_e(
                    self,
                    m.span,
                    E_PARTIAL_MOVE,
                    $"cannot move field `{ma.member}` out of `{o.fqn}` from outside its defining module `{o.module}`",
                )
                None => {}
            }
        }
        _ => {}
    }
    return inner
}

// Append the derivation behind `ty`'s copyable bit - one clause per hop, outermost first, each
// prefixed with "; " so it reads as a tail on whatever the diagnostic said first. Nothing is
// appended when `ty` is copyable. A type several hops from any `owned` still refuses to be copied,
// and the chain is the only thing in the message that says why.
fn append_copy_blame(self: &Checker, ty: Ty, sb: &StringBuilder) {
    let hops: List(CopyBlame) = list(2)
    defer hops.deinit()
    solve_within(self, ty)
    self.engine.copy_blame(ty, &hops)
    for i in 0..hops.len {
        sb.append("; `")
        format_with_names(
            &self.engine.interner,
            self.engine.zonk(hops[i].owner),
            sb,
            Some(&self.nominals),
            Some(&self.tp_names),
        )
        const what = if hops[i].variant { "variant" } else { "field" }
        sb.append($"` is not copyable: {what} `{hops[i].field}` is ")
        hops[i].field_ty match {
            Some(ft) => {
                sb.append("`")
                format_with_names(
                    &self.engine.interner,
                    self.engine.zonk(ft),
                    sb,
                    Some(&self.nominals),
                    Some(&self.tp_names),
                )
                sb.append("`")
            }
            None => sb.append("`owned`")
        }
    }
    const leaf = if hops.len == 0 { Some(ty) } else { hops[hops.len - 1].field_ty }
    if leaf.is_none() or !self.engine.is_rigid(leaf.unwrap()) {
        return
    }
    const name = ty_node(self, self.engine.resolve(leaf.unwrap())) match {
        NVar(v) => self.tp_names.get(v.id) ?? "T"
        _ => "T"
    }
    sb.append($"; `{name}` is a type parameter: copying it needs `where {name}: copyable`")
}

// The expression forms `move` accepts: the grammar of an assignment target (spec 3.4.1). A call is
// not one of them - it returns a value with no storage of its own, which is what separates this
// from `is_place_expr`, where `&f()` is legal because the call may return a reference.
fn is_move_operand(e: &Expr) bool {
    return e.* match {
        Identifier(_) => true
        MemberAccess(_) => true
        Index(_) => true
        Dereference(_) => true
        _ => false
    }
}

fn check_address_of(self: &Checker, a: &AddressOfExpr) Ty {
    let inner = check_expr(self, a.operand)
    if in_current_context(self, a.operand) {
        push_diag_e(
            self,
            a.span,
            E_CONTEXT_PLACE,
            from_view("the current context has no address - copy it first (`let c = context`)"),
        )
        return self.engine.mk_ref(inner)
    }
    // A reference to a value with no storage would outlive it (E2040).
    if !is_place_expr(a.operand) {
        push_diag_e(
            self,
            a.span,
            E_ADDR_OF_TEMPORARY,
            from_view("cannot take the address of a temporary - bind it to a variable first"),
        )
    }
    return self.engine.mk_ref(inner)
}

// The expression forms that name storage. Everything else is a value computed on the spot, whose
// address dies with the enclosing statement. A call is deliberately included: it may return a
// reference, and the reference checker allows `&f()` for that reason.
fn is_place_expr(e: &Expr) bool {
    return e.* match {
        Identifier(_) => true
        MemberAccess(_) => true
        Index(_) => true
        Dereference(_) => true
        Call(_) => true
        _ => false
    }
}

// `-x`, `!x`, `~x`. `!` fixes both sides to bool; `-` and `~` type as their operand, so a
// suffix-less literal operand stays open for the context to resolve. Numeric-ness of `-`/`~`
// operands is not enforced yet - rejection power lags the reference here (docs/self-host.md) - but
// the operand subtree is visited and the node gets a real type, which is what lowering's
// width/float decisions read.
fn check_unary(self: &Checker, u: &UnaryExpr) Ty {
    let inner = check_expr(self, u.operand)
    return u.op match {
        Not => {
            unify_expected(self, inner, prim_of(PrimitiveKind.Bool), E_TYPE_MISMATCH, u.span)
            prim_of(PrimitiveKind.Bool)
        }
        Neg => inner
        BitNot => {
            // `~` is a bit pattern operation: bools have no bits to flip in FLang's model, and
            // floats have no meaningful ones.
            let z = self.engine.resolve(inner)
            let bad = ty_node(self, z) match {
                NPrim(p) => p == PrimitiveKind.Bool or is_float(p)
                NNominal(_) => true
                _ => false
            }
            if bad {
                push_diag_e(
                    self,
                    u.span,
                    E_OP_NO_IMPL,
                    from_view("no `op_bnot` implementation for this operand type"),
                )
            }
            inner
        }
    }
}

// The `T` of an `Option(T)`, or null when `ty` is not the well-known Option nominal.
fn option_inner(self: &Checker, ty: Ty) Ty? {
    let nn = ty_node(self, ty) match {
        NNominal(n) => n
        _ => return null
    }
    let id = self.nominals.by_fqn.get(FQN_OPTION)
    if id.is_none() {
        return null
    }
    if id.unwrap() != nn.id {
        return null
    }
    if nn.args.len != 1 {
        return null
    }
    return Some(self.engine.interner.child_at(nn.args, 0))
}

// `a ?? b` - `a` must be `Option(T)`. Two result shapes, matching the reference checker: `Option(T)
// ?? Option(T)` chains and keeps the Option; `Option(T) ?? T` unwraps to `T`. The stdlib's
// `op_coalesce` overloads exist only for Option and are shadowed by these built-in paths, so no
// operator dispatch happens here (the reference resolves the same way).
fn check_coalesce(self: &Checker, c: &CoalesceExpr) Ty {
    let lhs = self.engine.resolve(check_expr(self, c.lhs))
    // Poison absorbs: the operand's error is already reported.
    if lhs.is_error() {
        let _r = check_expr(self, c.rhs)
        return TY_ERROR
    }
    let inner = option_inner(self, lhs)
    if inner.is_none() {
        let _r = check_expr(self, c.rhs)
        push_diag_e(
            self,
            c.span,
            E_TYPE_MISMATCH,
            from_view("left operand of `??` must be an Option"),
        )
        return self.engine.fresh_var()
    }
    let t = inner.unwrap()
    let rhs = check_expr(self, c.rhs)
    let rres = self.engine.resolve(rhs)
    let rinner = option_inner(self, rres)
    if rinner.is_some() {
        unify_expected(self, rinner.unwrap(), t, E_TYPE_MISMATCH, c.span)
        return lhs
    }
    unify_expected(self, rhs, t, E_TYPE_MISMATCH, c.span)
    return t
}

// `a?.b` (RFC-010) - the receiver must be `Option(T)` with `T` a struct carrying field `b`. Types
// as `Option(field)` - unless the field is
// already an Option, which passes through unwrapped (§"`?.` lifts and
// flattens": no `Option(Option(U))`). Mirrors the reference's `InferNullPropagation`;
// `struct_field_lookup` substitutes a generic inner's type arguments like any field read.
fn check_null_prop(self: &Checker, np: &NullPropagationExpr) Ty {
    let recv = self.engine.resolve(check_expr(self, np.receiver))
    // Poison absorbs: the receiver's error is already reported.
    if recv.is_error() {
        return TY_ERROR
    }
    let inner = option_inner(self, recv)
    if inner.is_none() {
        push_diag_e(
            self,
            np.span,
            E_TYPE_MISMATCH,
            from_view("null propagation `?.` requires an Option receiver"),
        )
        return self.engine.fresh_var()
    }
    let t = inner.unwrap()
    let fty = struct_field_lookup(self, t, np.member)
    if fty.is_none() {
        push_diag_e(
            self,
            np.span,
            E_TYPE_MISMATCH,
            from_view("`?.` names no field on the Option's inner type"),
        )
        return self.engine.fresh_var()
    }
    let f = self.engine.resolve(fty.unwrap())
    if option_inner(self, f).is_some() {
        return f
    }
    let id = self.nominals.by_fqn.get(FQN_OPTION)
    if id.is_none() {
        return TY_ERROR
    }
    let args: List(Ty) = list(1)
    args.push(f)
    return mk_nominal(self, id.unwrap(), args)
}

// `expr?` (RFC-009). The reference desugars into a synthesized `op_try(expr) match { Continue(v) =>
// v, Return(r) => return r }` AST and infers over that; node ids here are span-keyed, so
// synthesized nodes would collide with real ones. The shape is checked directly instead - resolve
// `op_try` against the operand, require its return to be `TryResult(T, R)`, take `T` as the
// expression's type, and unify `R` with the enclosing function's declared return - exactly what
// inference over the desugar concludes. The pick is recorded for lowering, which emits the call,
// the tag branch, and the early return itself.
fn check_try(self: &Checker, t: &TryExpr) Ty {
    let operand = check_expr(self, t.operand)
    // A `defer` body runs on the way OUT of the function; there is no return path left for `?` to
    // take (E2091).
    if self.defer_depth > 0 {
        push_diag_e(
            self,
            t.span,
            E_TRY_IN_DEFER,
            from_view(
                "`?` cannot be used inside a `defer` body - the function is already returning",
            ),
        )
        return self.engine.fresh_var()
    }
    if self.fn_stack.len == 0 {
        push_diag_e(self, t.span, E_TRY_OUTSIDE_FN, from_view("`?` operator outside of a function"))
        return self.engine.fresh_var()
    }

    let args: List(Ty) = list(1)
    args.push(operand)
    let pick = operator_pick(self, "op_try", &args, t.span)
    args.deinit()
    if pick.is_none() {
        push_diag_e(
            self,
            t.span,
            E_NO_OP_TRY,
            from_view("the `?` operator requires an `op_try` overload for the operand type"),
        )
        return self.engine.fresh_var()
    }
    let p = pick.unwrap()

    let nr = ty_node(self, self.engine.resolve(p.ret)) match {
        NNominal(n) => Some(n)
        _ => null
    }
    let tr_id = self.nominals.by_fqn.get(FQN_TRY_RESULT)
    let ok = nr.is_some() and tr_id.is_some()
    if ok {
        ok = nr.unwrap().id == tr_id.unwrap() and nr.unwrap().args.len == 2
    }
    if !ok {
        push_diag_e(self, t.span, E_NO_OP_TRY, from_view("`op_try` must return `TryResult(T, R)`"))
        return self.engine.fresh_var()
    }
    let n = nr.unwrap()

    // The early-returned `R` must fit the enclosing function's declared return type - the
    // constraint the desugar's `return r` arm imposes.
    let frame = &self.fn_stack[self.fn_stack.len - 1]
    unify_expected(
        self,
        self.engine.interner.child_at(n.args, 1),
        frame.return_ty,
        E_RETURN_MISMATCH,
        t.span,
    )

    self.results.record_operator(
        self.node_of(t.span),
        ResolvedOperator {
            function_id = p.id,
            negate_result = false,
            cmp_derived_op = null,
            is_ref_form = false,
            spec_id = null,
            lhs_hops = 0u32,
            rhs_hops = 0u32,
        },
    )
    note_pending(self, t.span, true, &p)
    return self.engine.interner.child_at(n.args, 0)
}

// `operand.*` - peels one reference. A nominal operand dispatches to its `op_deref(&X) &T` (the
// explicit form of the UFCS peel): the pick is recorded as an operator on the deref node so
// lowering calls it, and the expression types as `T`. Anything else defers to a fresh var so an
// already-reported error does not cascade.
fn check_deref(self: &Checker, d: &DereferenceExpr) Ty {
    let t = self.engine.resolve(check_expr(self, d.operand))
    // An unresolved operand may still become a reference; anything else concrete never will
    // (E2012).
    let open = self.engine.is_var(t) or t.is_error()
    if !open {
        let derefable = ty_node(self, t) match { NRef(_) => true, NNominal(_) => true, _ => false }
        if !derefable {
            push_diag_e(
                self,
                d.span,
                E_CANNOT_DEREF,
                from_view("cannot dereference a value that is not a reference"),
            )
            return TY_ERROR
        }
    }
    return ty_node(self, t) match {
        NRef(inner) => inner
        NNominal(_) => user_deref(self, t, d.span)
        _ => self.engine.fresh_var()
    }
}

fn user_deref(self: &Checker, t: Ty, span: SourceSpan) Ty {
    let args: List(Ty) = list(1)
    args.push(self.engine.mk_ref(t))
    let pick = operator_pick(self, "op_deref", &args, span)
    args.deinit()
    if pick.is_none() {
        return self.engine.fresh_var()
    }
    let p = pick.unwrap()
    let inner = ty_node(self, self.engine.resolve(p.ret)) match {
        NRef(i) => i
        _ => return self.engine.fresh_var()
    }
    self.results.record_operator(
        self.node_of(span),
        ResolvedOperator {
            function_id = p.id,
            negate_result = false,
            cmp_derived_op = null,
            is_ref_form = true,
            spec_id = null,
            lhs_hops = 0u32,
            rhs_hops = 0u32,
        },
    )
    note_pending(self, span, true, &p)
    return inner
}

// `a..b` - a half-open `Range(T)`. Both bounds unify with each other, so `0..n` takes `n`'s type. A
// partial range (`a..`, `..b`, `..`) still has a `Range` type: the bound that is written fixes the
// element, and `..` leaves it free. Whether the missing bound can be supplied is the index site's
// problem, not the type's.
fn check_range(self: &Checker, r: &RangeExpr) Ty {
    let s = r.start match { Some(e) => Some(check_expr(self, e)), None => null }
    let e = r.end match { Some(x) => Some(check_expr(self, x)), None => null }
    let elem = s match {
        Some(st) => {
            e match {
                Some(en) => unify_expected(self, en, st, E_TYPE_MISMATCH, r.span)
                None => {}
            }
            st
        }
        None => e match {
            Some(en) => en
            None => self.engine.fresh_var()
        }
    }
    return mk_range(self, elem)
}

fn mk_range(self: &Checker, elem: Ty) Ty {
    let id = self.nominals.by_fqn.get(FQN_RANGE)
    if id.is_none() {
        return TY_ERROR
    }
    let args: List(Ty) = list(1)
    args.push(elem)
    return mk_nominal(self, id.unwrap(), args)
}

fn mk_slice_ty(self: &Checker, elem: Ty) Ty {
    let id = self.nominals.by_fqn.get(FQN_SLICE)
    if id.is_none() {
        return TY_ERROR
    }
    let args: List(Ty) = list(1)
    args.push(elem)
    return mk_nominal(self, id.unwrap(), args)
}

// True when `t` is the well-known `Range` nominal. An index of range type selects the slicing form
// of indexing rather than element access.
fn is_range_ty(self: &Checker, t: Ty) bool {
    let n = ty_node(self, t) match { NNominal(nn) => nn, _ => return false }
    let id = self.nominals.by_fqn.get(FQN_RANGE)
    if id.is_none() {
        return false
    }
    return id.unwrap() == n.id
}

// The element of a built-in indexable base: a fixed array, or the well-known `Slice` nominal. Null
// for everything else, which routes the index through the user-defined operators.
fn builtin_element(self: &Checker, t: Ty) Ty? {
    return ty_node(self, t) match {
        NArray(a) => Some(a.elem)
        NNominal(n) => slice_element(self, &n)
        _ => null
    }
}

fn slice_element(self: &Checker, n: &NNominalNode) Ty? {
    let id = self.nominals.by_fqn.get(FQN_SLICE)
    if id.is_none() {
        return null
    }
    if id.unwrap() != n.id {
        return null
    }
    if n.args.len != 1 {
        return null
    }
    return Some(self.engine.interner.child_at(n.args, 0))
}

// `base[index]`.
//
// Built-in array and slice indexing is tried BEFORE the user-defined operators, mirroring the
// reference checker. The order is not cosmetic: `String` and `Slice(u8)` coerce to each other in
// both directions, so `op_index(String, Range)` would otherwise capture `Slice(u8)[range]`.
//
// User types dispatch to one of two mutually exclusive operator shapes:
//   ref-form   `op_index_ref(&Self, Idx) &T` - a place: read, write, `&x[i]`
//   value-form `op_index(Self|&Self, Idx) T` - a computed read
// The winner is recorded on the index node with `is_ref_form` set, so lowering emits a call plus a
// load, or the call alone.
fn check_index(self: &Checker, idx: &IndexExpr) Ty {
    let base_ty = check_expr(self, idx.receiver)
    let index_ty = check_expr(self, idx.index)

    let rbase = self.engine.resolve(base_ty)
    let rindex = self.engine.resolve(index_ty)
    let ranged = is_range_ty(self, rindex)

    if !ranged {
        let is_bool = rindex == prim_of(PrimitiveKind.Bool)
        if is_bool {
            push_diag_e(
                self,
                expr_span(idx.index),
                E_BAD_INDEX_TYPE,
                from_view("cannot use `bool` as an index type"),
            )
            return self.engine.fresh_var()
        }
    }

    let elem = builtin_element(self, rbase)
    if elem.is_some() {
        // `xs[a..b]` yields a view of the same element type; the bounds are `usize`. `xs[i]` yields
        // the element.
        if ranged {
            constrain_range_usize(self, rindex, idx.span)
            // Route through the stdlib's clamping `op_index($T[], Range)` so lowering has a
            // callable pick (M11). The base is already a built-in slice/array here, so the String
            // overload cannot capture it (the concern that keeps builtin indexing FIRST). No
            // visible overload - a prelude-less unit - falls back to the direct typing; such a site
            // refuses at lowering.
            let pick = operator_pick_2(self, "op_index", rbase, rindex, idx.span)
            if pick.is_some() {
                let p = pick.unwrap()
                self.results.record_operator(
                    self.node_of(idx.span),
                    ResolvedOperator {
                        function_id = p.id,
                        negate_result = false,
                        cmp_derived_op = null,
                        is_ref_form = false,
                        spec_id = null,
                        lhs_hops = 0u32,
                        rhs_hops = 0u32,
                    },
                )
                note_pending(self, idx.span, true, &p)
                return p.ret
            }
            return mk_slice_ty(self, elem.unwrap())
        }
        unify_expected(self, index_ty, ty_usize(), E_TYPE_MISMATCH, expr_span(idx.index))
        return elem.unwrap()
    }

    return user_index(self, idx, base_ty, rbase, index_ty)
}

// The span of an open-ended range index (`xs[a..]`, `xs[..]`), whose end the receiver's `len`
// fills; null for any other index.
fn open_range_span(idx: &IndexExpr) SourceSpan? {
    return idx.index.* match {
        Range(r) => if r.end.is_none() { Some(r.span) } else { null }
        _ => null
    }
}

// `xs[a..]` on a user type fills its end from `xs.len`. When the receiver has no `len` of its own,
// or the index itself resolved through `op_deref` (so the `len` that matters is the inner one), the
// hop chain from the receiver as written to the `len` is recorded on the range node for lowering to
// follow.
fn record_open_range_len(self: &Checker, idx: &IndexExpr, rbase: Ty, hops: usize) {
    let rs = open_range_span(idx)
    if rs.is_none() {
        return
    }
    if hops > 0 or !has_direct_field(self, rbase, "len") {
        let _ty = member_deref_retry_at(self, "len", rs.unwrap(), rbase)
    }
}

// Whether `recv` (one reference peeled) is a nominal declaring `member` itself.
fn has_direct_field(self: &Checker, recv: Ty, member: String) bool {
    let r = self.engine.resolve(recv)
    let peeled = ty_node(self, r) match {
        NRef(inner) => self.engine.resolve(inner)
        _ => r
    }
    return struct_field_lookup(self, peeled, member).is_some()
}

// A range used as an index counts in elements, so its bounds are `usize`.
fn constrain_range_usize(self: &Checker, rindex: Ty, span: SourceSpan) {
    let n = ty_node(self, rindex) match { NNominal(nn) => nn, _ => return }
    if n.args.len != 1 {
        return
    }
    unify_expected(
        self,
        self.engine.interner.child_at(n.args, 0),
        ty_usize(),
        E_TYPE_MISMATCH,
        span,
    )
}

// User-defined indexing. Ref-form wins when it resolves; the reference checker additionally reports
// E2077 when a type declares both forms, which needs a non-committing probe of the loser and is not
// done here - the pick is the same either way, only the diagnostic is missing.
fn user_index(self: &Checker, idx: &IndexExpr, base_ty: Ty, rbase: Ty, index_ty: Ty) Ty {
    // An unresolved base cannot arbitrate an overload set; committing the first match would bind it
    // arbitrarily.
    if self.engine.is_var(rbase) {
        return self.engine.fresh_var()
    }

    // Each form is resolved as the method call it desugars to: the base as written, as `&Self` or
    // the pointee, or peeled through `op_deref` (a `List` indexing its storage), one ranked set.
    let extra: List(Ty) = list(1)
    defer extra.deinit()
    extra.push(index_ty)

    let ref_pick = receiver_pick(self, "op_index_ref", base_ty, &extra, idx.span, idx.span)
    if ref_pick.is_some() {
        // Both forms declared for one (Self, Idx): the ref form wins deterministically, but the two
        // patterns are mutually exclusive by design - say so rather than silently picking (E2077).
        let both = index_operator(self, "op_index", base_ty, index_ty, idx.span)
        if both.is_some() {
            push_diag_e(
                self,
                idx.span,
                E_INDEX_AMBIGUOUS,
                from_view(
                    "both `op_index` and `op_index_ref` are declared for this type and index - declare only one",
                ),
            )
        }
        let p = ref_pick.unwrap()
        // The declared return is `&T`; the expression's type is `T`.
        let inner = ty_node(self, self.engine.resolve(p.ret)) match {
            NRef(i) => i
            _ => self.engine.fresh_var()
        }
        self.results.record_operator(
            self.node_of(idx.span),
            ResolvedOperator {
                function_id = p.id,
                negate_result = false,
                cmp_derived_op = null,
                is_ref_form = true,
                spec_id = null,
                lhs_hops = 0u32,
                rhs_hops = 0u32,
            },
        )
        note_pending(self, idx.span, true, &p)
        record_open_range_len(self, idx, rbase, p.hops)
        return inner
    }

    let value_pick = receiver_pick(self, "op_index", base_ty, &extra, idx.span, idx.span)
    if value_pick.is_some() {
        let p = value_pick.unwrap()
        self.results.record_operator(
            self.node_of(idx.span),
            ResolvedOperator {
                function_id = p.id,
                negate_result = false,
                cmp_derived_op = null,
                is_ref_form = false,
                spec_id = null,
                lhs_hops = 0u32,
                rhs_hops = 0u32,
            },
        )
        note_pending(self, idx.span, true, &p)
        record_open_range_len(self, idx, rbase, p.hops)
        return p.ret
    }

    push_diag_e(
        self,
        idx.span,
        E_NOT_INDEXABLE,
        from_view(
            "type does not support indexing: declare `op_index_ref(&Self, Idx) &T` or `op_index(Self, Idx) T`",
        ),
    )
    return self.engine.fresh_var()
}

// Resolve one indexing operator against the visible registry candidates. Unlike a call site this
// must not report on failure - the caller tries several shapes and reports once at the end.
fn index_operator(
    self: &Checker,
    name: String,
    self_ty: Ty,
    index_ty: Ty,
    span: SourceSpan,
) OverloadPick? {
    let args: List(Ty) = list(2)
    args.push(self_ty)
    args.push(index_ty)
    let pick = operator_pick(self, name, &args, span)
    args.deinit()
    return pick
}

// Resolve one operator function (`op_index`, `op_try`, ...) against the visible registry
// candidates. Unlike a call site this must not report on failure - callers try several shapes, or
// supply their own diagnostic, and report once at the end.
fn operator_pick(self: &Checker, name: String, args: &List(Ty), span: SourceSpan) OverloadPick? {
    let vis = fn_visibility(self)
    defer vis.deinit()
    let cands = self.functions.lookup(name, &vis) match {
        FnLookFound(c) => Some(move c)
        _ => null
    }
    if cands.is_none() {
        return null
    }
    let candidates = cands.unwrap()

    // Probe first: `resolve_overload` commits its unifications and reports mismatches, so a losing
    // shape would both pollute the substitution and emit a diagnostic the caller is about to
    // supersede.
    let viable = false
    for i in 0..candidates.len {
        if probe_candidate(self, candidates[i], args).is_some() {
            viable = true
        }
    }
    let pick = if viable { resolve_overload(self, &candidates, args, span) } else { null }

    candidates.deinit()
    return pick
}

// `expr as T` yields `T`; cast validity (representability, pointer compatibility) is a later pass,
// matching the reference checker. A BARE numeric literal operand takes the target type directly -
// `0xFFFF_FFFF as u64` means a u64-typed constant, and without the pin the literal's var would go
// unresolved (E2001). Non-literal operands keep their own type; the cast converts.
fn check_cast(self: &Checker, c: &CastExpr) Ty {
    let v = check_expr(self, c.operand)
    let target = resolve_type_expr(self, c.target)
    let is_bindable_lit = c.operand.* match {
        Lit(l) => l.value match {
            Int(_) => true
            Float(_) => true
            _ => false
        }
        // `.{ ... } as T`: the cast IS the anonymous literal's context - without the pin its var
        // never settles (M11). (Shaped as a match rather than `.is_none()`: the reference compiler
        // mis-lowers a niche-option method receiver read from a match-payload copy.)
        StructLit(sl) => sl.type_expr match {
            Some(_) => false
            None => true
        }
        _ => false
    }
    if is_bindable_lit {
        // Best-effort: a numeric target binds the literal; a failure (casting a literal to a
        // pointer, say) is the cast's business, not a unification diagnostic.
        let _o = self.engine.unify(v, literal_cast_ty(self, target))
    }
    let from = self.engine.resolve(v)
    let to = self.engine.resolve(target)
    let open = self.engine.is_var(from) or self.engine.is_var(to) or from.is_error()
        or to.is_error()
    const valid = open or cast_valid(self, from, to)
    if !valid {
        push_diag_e(self, c.span, E_INVALID_CAST, from_view("invalid cast between these types"))
    }
    if !open and valid {
        report_unknown_tag(self, c, to)
    }
    if !open {
        report_ref_int_cast(self, c, from, to)
    }
    return target
}

// `13 as Month`: an integer literal that no variant of the target enum carries names no value of
// it.
fn report_unknown_tag(self: &Checker, c: &CastExpr, to: Ty) {
    const text = c.operand.* match {
        Lit(l) => l.value match {
            Int(n) => Some(n.text)
            _ => null
        }
        _ => null
    }
    const enum_id = ty_node(self, to) match {
        NNominal(nn) => Some(nn.id)
        _ => null
    }
    if text.is_none() or enum_id.is_none() {
        return
    }
    const tag = parse_i64_text(text.unwrap())
    if enum_has_tag(&self.nominals, enum_id.unwrap(), tag) {
        return
    }
    push_diag_e(
        self,
        c.span,
        E_INVALID_CAST,
        $"no variant of this enum has the tag `{text.unwrap()}`",
    )
}

// The type a literal operand of `as target` takes: the target itself, or for an enum its i32
// discriminant, so `12 as Month` reads as `12i32 as Month` (and a payload enum target is refused by
// cast_valid rather than left unchecked).
fn literal_cast_ty(self: &Checker, target: Ty) Ty {
    const is_enum = ty_node(self, self.engine.resolve(target)) match {
        NNominal(nn) => is_enum_id(self, nn.id)
        _ => false
    }
    return if is_enum { prim_of(PrimitiveKind.I32) } else { target }
}

// The two directions between a reference and an integer (spec §5.4). Reading an address out as an
// integer is allowed and warns; building a reference from an integer is not allowed at all, so an
// address can leave the escape analysis but cannot come back and be written through.
fn report_ref_int_cast(self: &Checker, c: &CastExpr, from: Ty, to: Ty) {
    const f_ref = ty_node(self, from) match { NRef(_) => true, _ => false }
    const t_ref = ty_node(self, to) match { NRef(_) => true, _ => false }
    const f_prim = ty_node(self, from) match { NPrim(p) => Some(p), _ => null }
    const t_prim = ty_node(self, to) match { NPrim(p) => Some(p), _ => null }

    if f_prim.is_some() and t_ref and is_pointer_sized(f_prim.unwrap()) {
        if !is_zero_literal(c.operand) {
            push_diag_e(
                self,
                c.span,
                E_INT_TO_REF,
                from_view(
                    "cannot cast an integer to a reference; take the address of a value instead",
                ),
            )
        }
        return
    }
    if f_ref and t_prim.is_some() and is_pointer_sized(t_prim.unwrap()) {
        push_diag_w(
            self,
            c.span,
            W_REF_TO_INT,
            from_view("casting a reference to an integer; the address cannot be cast back"),
        )
    }
}

// `0 as &T` spells a null reference while the language has no null primitive, and is exempt from
// E2122: a zero carries no address. Matched on the literal's source text, which the AST preserves;
// a suffix does not change the value.
fn is_zero_literal(e: &Expr) bool {
    return e.* match {
        Lit(l) => l.value match {
            Int(n) => n.text == "0"
            _ => false
        }
        _ => false
    }
}

// Explicit `as` casts only - implicit conversions go through coercion. Mirrors the reference's
// `IsCastValid`, including its one refusal: an integer to a PAYLOAD-carrying enum would leave the
// payload bytes uninitialized, so only bare enums accept a tag.
fn cast_valid(self: &Checker, from: Ty, to: Ty) bool {
    if from == to {
        return true
    }
    let fp = ty_node(self, from) match { NPrim(p) => Some(p), _ => null }
    let tp = ty_node(self, to) match { NPrim(p) => Some(p), _ => null }
    if fp.is_some() and tp.is_some() {
        return cast_prim(fp.unwrap()) and cast_prim(tp.unwrap())
    }
    let f_ref = ty_node(self, from) match { NRef(_) => true, _ => false }
    let t_ref = ty_node(self, to) match { NRef(_) => true, _ => false }
    if f_ref and t_ref {
        return true
    }
    if f_ref and tp.is_some() {
        return is_pointer_sized(tp.unwrap())
    }
    if fp.is_some() and t_ref {
        return is_pointer_sized(fp.unwrap())
    }

    let f_nom = ty_node(self, from) match { NNominal(_) => true, _ => false }
    let t_nom_id = ty_node(self, to) match { NNominal(nn) => Some(nn.id), _ => null }
    let f_arr = ty_node(self, from) match { NArray(_) => true, _ => false }
    let f_aggregate = f_nom or f_arr
    if f_aggregate and t_nom_id.is_some() {
        return true
    }
    let f_enum = ty_node(self, from) match {
        NNominal(nn) => is_enum_id(self, nn.id)
        _ => false
    }
    if f_enum and tp.is_some() {
        return true
    }
    if fp.is_some() and t_nom_id.is_some() {
        if !is_enum_id(self, t_nom_id.unwrap()) {
            return false
        }
        return enum_payloadless(&self.nominals, t_nom_id.unwrap())
    }
    return false
}

fn is_enum_id(self: &Checker, id: NominalId) bool {
    return self.nominals.get(id).* match {
        NomEnum(_) => true
        _ => false
    }
}

// `bool` and `char` count as numeric for casting, matching the reference.
fn cast_prim(p: PrimitiveKind) bool {
    return is_numeric(p) or p == PrimitiveKind.Bool or p == PrimitiveKind.Char
}

fn is_pointer_sized(p: PrimitiveKind) bool {
    return p == PrimitiveKind.USize or p == PrimitiveKind.ISize
}

// `()` is unit - the empty tuple and `void` are the same type.
fn check_tuple_lit(self: &Checker, t: &TupleLiteralExpr) Ty {
    if t.elements.len == 0 {
        return TY_VOID
    }
    let elems = list(t.elements.len)
    for &e in t.elements {
        elems.push(check_expr(self, e))
    }
    return mk_tuple(self, elems)
}

fn check_literal(self: &Checker, lit: &LiteralExpr) Ty {
    return literal_value_ty(self, lit.value)
}

// The type of a literal form. Shared with pattern checking, where the same seven forms appear
// without an enclosing expression node.
fn literal_value_ty(self: &Checker, value: LiteralValue) Ty {
    return value match {
        Int(il) => numeric_literal_ty(self, il.span, il.suffix, il.text, false)
        Float(fl) => numeric_literal_ty(self, fl.span, fl.suffix, fl.text, true)
        Bool(_) => prim_of(PrimitiveKind.Bool)
        String(_) => string_type(self)
        Char(_) => prim_of(PrimitiveKind.Char)
        Byte(_) => prim_of(PrimitiveKind.U8)
        Null => option_of_fresh(self)
    }
}

// A suffixed numeric literal IS its suffix's primitive; an unsuffixed one is a fresh var the
// context resolves, recorded so `validate_literals` can report the ones nothing ever pinned (E2001,
// as in the reference) instead of letting an unresolved var drift into lowering.
fn numeric_literal_ty(
    self: &Checker,
    span: SourceSpan,
    suffix: String,
    text: String,
    is_float: bool,
) Ty {
    if suffix.len > 0 {
        let p = prim_from_name(suffix)
        if p.is_some() {
            // A suffixed literal never becomes a pending literal, so its range check happens here
            // rather than in `validate_literals`.
            if !is_float {
                check_int_range(self, text, p.unwrap(), span)
            }
            return prim_of(p.unwrap())
        }
    }
    let v = self.engine.fresh_constrained_var(literal_prim_set(is_float))
    self.pending_literals.push(PendingLit { span = span, ty = v, text = text, is_float = is_float })
    return v
}

// The kinds an unsuffixed literal may settle on, as the engine's constraint set. The constraint is
// what makes unification reject a candidate whose parameter no numeric literal can inhabit, so
// overload resolution ranks `dict(100)` on the capacity overload rather than the allocator one.
// `validate_literals` still reports the literal that never resolved (E2001) or resolved out of
// range (E2029); this only decides what unification will accept.
fn literal_prim_set(is_float: bool) PrimSet {
    let out: PrimSet = 0u32
    for i in 0..14u32 {
        prim_kind_at(i) match {
            Some(k) => {
                if literal_prim_ok(k, is_float) {
                    out = out | prim_bit(k)
                }
            }
            None => {}
        }
    }
    return out
}

fn string_type(self: &Checker) Ty {
    let id = self.nominals.by_fqn.get(FQN_STRING)
    if id.is_none() {
        return TY_ERROR
    }
    let empty: List(Ty) = list(0)
    return mk_nominal(self, id.unwrap(), empty)
}

fn option_of_fresh(self: &Checker) Ty {
    let id = self.nominals.by_fqn.get(FQN_OPTION)
    if id.is_none() {
        return TY_ERROR
    }
    let args: List(Ty) = list(1)
    args.push(self.engine.fresh_var())
    return mk_nominal(self, id.unwrap(), args)
}

fn check_identifier(self: &Checker, id: &IdentifierExpr) Ty {
    let b = self.env.lookup(id.name)
    if b.is_some() {
        let binding = b.unwrap()
        self.results.record_target(self.node_of(id.span), ResolvedTarget.RtLocal(binding.decl))
        if self.lambda_frames.len > 0 and !binding.is_type_param {
            note_capture(self, id.name, binding)
        }
        const bound = self.engine.specialize(&binding.scheme)
        // A type parameter in VALUE position is a reified type, exactly as a bare concrete type
        // name is (`size_of(i32)`). Handing back the raw parameter var instead lets a `Type($X)`
        // parameter unify with it while it is still free, binding the type parameter to `Type($X)`.
        if binding.is_type_param {
            return reified_type_of(self, bound)
        }
        return bound
    }

    let vis = fn_visibility(self)
    defer vis.deinit()

    // Module-level constant? Consts resolve BEFORE function-as-value, matching the reference
    // checker, where module consts live in the scope environment: `stdin` (a const File in
    // std.io.file) must not turn into the function value `std.process.stdin` when both modules are
    // imported. Record which one won (M11 globals): the FQN is interned into the result's
    // synth_strings so the view outlives the checker (lowering reads targets after `deinit`).
    let chit = self.constants.lookup_entry(id.name, &vis)
    if chit.is_some() {
        let h = chit.unwrap()
        let stable = self.results.add_synth_string(from_view(h.fqn))
        self.results.record_target(self.node_of(id.span), ResolvedTarget.RtConst(stable))
        return h.value
    }

    // Try function registry.
    let look = self.functions.lookup(id.name, &vis)
    let found: List(&FunctionScheme)? = look match {
        FnLookFound(candidates) => Some(move candidates)
        _ => null
    }
    if found.is_some() {
        let candidates = found.unwrap()
        defer candidates.deinit()
        if candidates.len == 1 {
            let c = candidates[0]
            self.results.record_target(self.node_of(id.span), ResolvedTarget.RtFunction(c.id))
            return self.engine.specialize(&c.signature)
        }
        // Multiple overloads as a value: mint a var the context pins, and park the site -
        // `resolve_fn_name_values` picks the
        // overload once the slot's Func shape settles (ticket 019 §4).
        let slot = self.engine.fresh_var()
        self.pending_fn_names.push(PendingFnName {
            span = id.span,
            ty = slot,
            name = id.name,
            module = self.current_module,
        })
        return slot
    }

    // Bare payload-less variant (`None`) - locals and functions win first.
    let vid = self.nominals.lookup_variant(id.name, 0usize, &vis)
    if vid.is_some() {
        let vt = construct_nullary(self, vid.unwrap(), id.name, id.span)
        if vt.is_some() {
            return vt.unwrap()
        }
    }

    // Bare type name in value position (`size_of(ArenaPage)`, `get_kind(i32)`): the identifier IS a
    // reified type - it types as `Type(T)`, the handle `core.rtti` declares, so `Type($T)`
    // parameters bind `$T` directly and lowering knows to build a TypeInfo rather than read a
    // binding. (The `T -> Type(T)` coercion stays for values that are not type names.)
    let prim = prim_from_name(id.name)
    if prim.is_some() {
        return reified_type_of(self, prim_of(prim.unwrap()))
    }
    let tn = self.nominals.lookup(id.name, &vis) match {
        NomLookFound(n) => Some(n)
        _ => null
    }
    if tn.is_some() {
        // `size_of(Box)` where `Box` is `struct(T)`: a reified type has to be a CONCRETE one, so
        // the arguments must be spelled (E2104).
        if nominal_arity(self, tn.unwrap()) > 0 {
            push_diag_e(
                self,
                id.span,
                E_BARE_GENERIC,
                $"generic type `{id.name}` needs its type arguments here",
            )
            return TY_ERROR
        }
        return reified_type_of(self, nominal_with_fresh_args(self, tn.unwrap()))
    }

    push_diag_e(self, id.span, E_UNKNOWN_IDENT, $"unknown identifier `{id.name}`")
    return TY_ERROR
}

// `core.rtti.Type(t)` - the reified handle for a type used as a value. Falls back to the bare type
// when `core.rtti` is not in the source set (a prelude-less unit still type-checks its own code).
fn reified_type_of(self: &Checker, t: Ty) Ty {
    let id = self.nominals.by_fqn.get(FQN_TYPE)
    if id.is_none() {
        return t
    }
    let args: List(Ty) = list(1)
    args.push(t)
    return mk_nominal(self, id.unwrap(), args)
}

fn nominal_arity(self: &Checker, id: NominalId) usize {
    return self.nominals.get(id).* match {
        NomStruct(s) => s.type_params.len
        NomEnum(e) => e.type_params.len
    }
}

fn nominal_with_fresh_args(self: &Checker, id: NominalId) Ty {
    let n = self.nominals.get(id).* match {
        NomStruct(s) => s.type_params.len
        NomEnum(e) => e.type_params.len
    }
    let args = list(n)
    for k in 0..n { args.push(self.engine.fresh_var()) }
    return mk_nominal(self, id, args)
}

// ─────────────────────────────────────────────────────────────────────
// Lambdas (RFC-014)
//
// No AST clone, mirroring M10: the literal's body is checked in place - captured names resolve
// through the outer scopes they were bound in, and the capture list is a side record (`LambdaInfo`)
// that lowering uses to project reads through the closure environment. A lambda in a generic
// template body records one LambdaInfo per instantiation (the record lands in the active overlay),
// each with its own symbol.
// ─────────────────────────────────────────────────────────────────────

// A name read that crosses a lambda boundary is a capture by reference: record it on every crossed
// frame, innermost included, so each enclosing closure's environment carries what a nested one
// takes from it.
fn note_capture(self: &Checker, name: String, binding: &Binding) {
    let d = self.env.lookup_depth(name)
    if d.is_none() {
        return
    }
    let found = d.unwrap()
    for &fr in self.lambda_frames {
        if found >= fr.boundary {
            continue
        }
        if captures_contain(fr, name) {
            continue
        }
        let ty = self.engine.specialize(&binding.scheme)
        fr.captures.push(CaptureRec { name = name, decl = binding.decl, ty = ty })
    }
}

fn captures_contain(fr: &LambdaFrame, name: String) bool {
    for i in 0..fr.captures.len {
        if fr.captures[i].name == name {
            return true
        }
    }
    return false
}

fn check_lambda(self: &Checker, lam: &LambdaExpr) Ty {
    // Frame first, then the parameter scope: a binding at or above `boundary` is lambda-local,
    // anything below it is a capture.
    self.env.push_scope()
    let boundary = self.env.depth() - 1
    let caps: List(CaptureRec) = list(0)
    self.lambda_frames.push(LambdaFrame {
        boundary = boundary,
        lam_span = lam.span,
        captures = move caps,
    })

    // Parameters: an annotation resolves; a bare name (the projector records its type as
    // `TypeExpr.Error`) mints a fresh var the surrounding context - or an instantiation's body
    // re-check - pins.
    let params: List(Ty) = list(lam.params.len)
    let moves = 0usize
    for &p in lam.params {
        let unannotated = p.type_expr match { Error(_) => true, _ => false }
        let ty = if unannotated { self.engine.fresh_var() }
        else { resolve_type_expr(self, p.type_expr) }
        moves = moves | move_bit_of(self, params.len, p.is_move, ty, p.span)
        const p_node = self.node_of(p.span)
        self.results.record_type(p_node, ty)
        self.env.bind(
            p.name,
            Binding { scheme = mono(ty), decl = p_node, is_const = false, is_type_param = false },
        )
        params.push(ty)
    }
    let ret = lam.return_type match {
        Some(rt) => resolve_type_expr(self, rt)
        None => self.engine.fresh_var()
    }

    self.fn_stack.push(FnFrame { name = "<lambda>", return_ty = ret, decl_span = lam.span })
    let body_ty = check_block(self, lam.body)
    // The implicit-return rule of `check_function_body`, plus: an unannotated return type with a
    // valueless body settles to void.
    if body_ty == TY_VOID {
        if self.engine.is_var(self.engine.resolve(ret)) {
            let _o = self.engine.unify(ret, TY_VOID)
        }
    } else {
        let ret_is_void = self.engine.resolve(ret) == TY_VOID
        if !ret_is_void {
            unify_expected(self, body_ty, ret, E_RETURN_MISMATCH, lam.span)
        }
    }
    let _f = self.fn_stack.pop()
    self.env.pop_scope()
    let frame = self.lambda_frames.pop().unwrap()

    let node = self.node_of(lam.span)
    let lid = self.next_lambda
    self.next_lambda = lid + 1u32

    if frame.captures.len == 0 {
        // Bare function pointer: the body lowers as a module-level function under `symbol`; the
        // literal is its address.
        let fn_params: List(Ty) = list(params.len)
        fn_params.push_all(params.as_slice())
        self.results.record_lambda(
            node,
            LambdaInfo {
                span = lam.span,
                params = move params,
                ret = ret,
                captures = move frame.captures,
                closure_id = null,
                symbol = $"__flang_lambda_{lid}",
            },
        )
        return self.engine.mk_func(fn_params, ret, moves)
    }

    // Capturing closure: synthesize the environment struct (one `&T` field per capture, RFC-033)
    // and record how to call it. The literal's type is the anonymous nominal - it can never unify
    // with a bare fn type (E2111); it travels through generic `$F` slots instead.
    let module_name = self.current_module.unwrap_or("__synthetic")
    let fields: List(Field) = list(frame.captures.len)
    for i in 0..frame.captures.len {
        fields.push(Field {
            name = frame.captures[i].name,
            ty = self.engine.mk_ref(frame.captures[i].ty),
            decl_span = none_span(),
            owned = false,
        })
    }
    let empty_tps: List(VarId) = list(0)
    let sd = StructDef {
        fqn = "",
        module = module_name,
        is_pub = true,
        type_params = move empty_tps,
        assoc_params = list(0),
        fields = move fields,
        decl_span = lam.span,
        deprecation = null,
        is_simd = false,
        is_foreign = false,
    }
    // Registered by stable key: a re-demand's body pass reclaims the id the previous demand's
    // identically-ordered lambda held (see `begin_demand`).
    let nid = register_collected(
        self,
        NominalDef.NomStruct(move sd),
        $"{module_name}.__Closure_{lid}",
    )

    let sym = $"__flang_closure_call_{lid}"
    let sig_params: List(Ty) = list(params.len)
    sig_params.push_all(params.as_slice())
    self.closures.set(
        nid,
        ClosureSig {
            params = move sig_params,
            ret = ret,
            symbol = from_view(sym.view),
            lambda_node = node,
        },
    )
    self.results.record_lambda(
        node,
        LambdaInfo {
            span = lam.span,
            params = move params,
            ret = ret,
            captures = move frame.captures,
            closure_id = Some(nid),
            symbol = move sym,
        },
    )
    let no_args: List(Ty) = list(0)
    return mk_nominal(self, nid, no_args)
}

fn check_block(self: &Checker, blk: &BlockExpr) Ty {
    self.env.push_scope()
    // A block containing a diverging statement produces no value: `never` is the bottom type and
    // unifies with anything, so a `match` arm or `if` branch that returns does not drag the result
    // type to `void`. Without it, `x match { A => return 1, B => false }` types as void and a
    // `bool`-returning function rejects its own body.
    //
    // ponytail: divergence is tracked per statement, so an `if` whose every branch returns is not
    // itself treated as diverging. Add that when a case needs it - it is a strictly larger
    // analysis, not a different one.
    let diverges = false
    for &stmt in blk.stmts {
        if check_stmt(self, stmt) {
            diverges = true
        }
    }
    let final_ty = blk.trailing match {
        Some(e) => check_expr(self, e)
        None => TY_VOID
    }
    self.env.pop_scope()
    if diverges {
        return TY_NEVER
    }
    return final_ty
}

// An expression statement discards its value; statement ifs get their own inference (branch types
// need not agree, mirroring the reference checker's statement-context if handling). Returns whether
// the statement diverges - `return`, `break` and `continue` transfer control away, so nothing after
// them is reached and the enclosing block produces no value.
fn check_stmt(self: &Checker, stmt: &Stmt) bool {
    stmt.* match {
        Let(ls) => check_let(self, &ls)
        Expression(es) => {
            let handled = es.expr match {
                If(ife) => {
                    check_if_stmt(self, &ife)
                    self.results.record_type(self.node_of(expr_span(es.expr)), TY_VOID)
                    true
                }
                _ => false
            }
            if !handled {
                let _r = check_expr(self, es.expr)
            }
        }
        Return(rs) => {
            check_return(self, &rs)
            return true
        }
        Break(_) => return true
        Continue(_) => return true
        For(fs) => check_for(self, &fs)
        While(ws) => {
            let _c = check_expr(self, ws.condition)
            let _b = check_block(self, ws.body)
        }
        Loop(ls) => { let _b = check_block(self, ls.body) }
        Defer(ds) => {
            self.defer_depth = self.defer_depth + 1
            let _e = check_expr(self, ds.expr)
            self.defer_depth = self.defer_depth - 1
        }
        IfDirective(ifd) => return check_if_directive_stmt(self, &ifd)
        _ => {}
    }
    return false
}

// `#if cond { … } else { … }` - the condition resolves against the
// host's compile-time context; only the active branch is checked (the inactive one parses but is
// never validated). Diverges exactly when the active branch diverges - the branch is a statement
// splice, not a runtime conditional.
fn check_if_directive_stmt(self: &Checker, ifd: &IfDirectiveStmt) bool {
    directive_outcome(self, ifd) match {
        Active(active) => {
            const stmts = if active { ifd.then_stmts } else { ifd.else_stmts }
            let diverges = false
            for i in 0..stmts.len {
                if check_stmt(self, &stmts[i]) {
                    diverges = true
                }
            }
            return diverges
        }
        Invalid(err) => {
            const span = err.span
            const code = err.code
            const message = take_message(err)
            push_diag_e(self, span, code, message)
            return false
        }
    }
    return false
}

// `for name in iterable { body }`. The loop variable is bound for the body's scope only. A range
// yields its bound type; any other iterable needs the iterator protocol, so the variable stays an
// unconstrained var rather than being wrongly constrained.
fn check_for(self: &Checker, fs: &ForStmt) {
    let elem = check_iterable_element(self, fs)
    self.env.push_scope()
    // The loop variable's type lives on its own name node, so a cursor on it resolves and
    // goto-definition on a read inside the body lands on the name.
    const var_node = self.node_of(fs.var_span)
    self.results.record_type(var_node, elem)
    self.env.bind(
        fs.var_name,
        Binding { scheme = mono(elem), decl = var_node, is_const = true, is_type_param = false },
    )
    let _b = check_block(self, fs.body)
    self.env.pop_scope()
}

fn check_iterable_element(self: &Checker, fs: &ForStmt) Ty {
    return fs.iterable.* match {
        Range(r) => check_range_bounds(self, &r)
        _ => {
            let it_ty = check_expr(self, fs.iterable)
            resolve_for_protocol(self, fs, it_ty)
        }
    }
}

// The iterator protocol (M11): `iter(&Iterable) -> State`, then `next(&State) -> Option(T)`; the
// loop variable is `T`. The `iter` pick records on the BODY block's node (the iterable expr may
// already carry its own operator - an indexing pick, say), the `next` pick on the FOR node - the
// two hooks `lower_for_iter` reads. When the protocol does not resolve, the loop variable stays a
// fresh var and the `for` refuses at lowering (the state of the world before this).
fn protocol_pick(self: &Checker, name: String, arg: Ty, span: SourceSpan) OverloadPick? {
    let args = list(1)
    args.push(arg)
    let pick = operator_pick(self, name, &args, span)
    args.deinit()
    return pick
}

fn resolve_for_protocol(self: &Checker, fs: &ForStmt, it_ty: Ty) Ty {
    let z = self.engine.resolve(it_ty)
    // `for &x in xs` asks for the by-reference protocol entry, `iter_ref`. Either is resolved as
    // the method call `for` desugars to (`xs.iter()`): the iterable as written, by reference, or
    // through `op_deref`, with the hop chain recorded beside the pick on the body node.
    const iter_name = if fs.by_ref { "iter_ref" } else { "iter" }
    let no_args: List(Ty) = list(0)
    let ip = receiver_pick(self, iter_name, z, &no_args, expr_span(fs.iterable), fs.body.span)
    if ip.is_none() {
        // An unresolved iterable may still become something iterable; a concrete one without `iter`
        // never will (E2021).
        if !self.engine.is_var(z) and !z.is_error() {
            push_diag_e(
                self,
                expr_span(fs.iterable),
                E_NO_ITER,
                $"type is not iterable: no `{iter_name}` function takes it",
            )
        }
        return self.engine.fresh_var()
    }
    let p = ip.unwrap()
    check_consuming_receiver(self, &p, iter_name, Some(z), expr_span(fs.iterable))
    self.results.record_operator(
        self.node_of(fs.body.span),
        ResolvedOperator {
            function_id = p.id,
            negate_result = false,
            cmp_derived_op = null,
            is_ref_form = false,
            spec_id = null,
            lhs_hops = 0u32,
            rhs_hops = 0u32,
        },
    )
    note_pending(self, fs.body.span, true, &p)

    let state = self.engine.resolve(p.ret)
    // A self-iterator's `iter` returns `&State`; `next(&State)` then takes it AS-IS - so try the
    // wrapped shape first, the state unchanged second (reference parity).
    let np = protocol_pick(self, "next", self.engine.mk_ref(state), fs.span)
    if np.is_none() {
        install(&np, protocol_pick(self, "next", state, fs.span))
    }
    if np.is_none() {
        if !self.engine.is_var(state) and !state.is_error() {
            push_diag_e(
                self,
                fs.span,
                E_NO_NEXT,
                from_view("iterator state has no `next` function"),
            )
        }
        return self.engine.fresh_var()
    }
    let n = np.unwrap()
    self.results.record_operator(
        self.node_of(fs.span),
        ResolvedOperator {
            function_id = n.id,
            negate_result = false,
            cmp_derived_op = null,
            is_ref_form = false,
            spec_id = null,
            lhs_hops = 0u32,
            rhs_hops = 0u32,
        },
    )
    note_pending(self, fs.span, true, &n)
    const borrows = p.hops == 0 and p.params.len > 0 and is_ref_ty(self, p.params[0])
    record_iter_release(self, fs, iter_owned(self, fs, z, state, borrows))

    let nret = self.engine.resolve(n.ret)
    let inner = option_inner(self, nret)
    if inner.is_none() and !self.engine.is_var(nret) and !nret.is_error() {
        push_diag_e(
            self,
            fs.span,
            E_NEXT_RETURN,
            from_view("`next` must return `Option(T)` - the loop ends when it yields `null`"),
        )
    }
    return inner match {
        Some(t) => t
        None => self.engine.fresh_var()
    }
}

// What the loop owns and must release: a non-copyable state `iter` handed it, as `for_each(it: move
// $I, body)` would own it, or else a non-copyable temporary iterable `iter` only borrowed, which
// nothing past the statement holds. Null when it owns neither.
fn iter_owned(self: &Checker, fs: &ForStmt, iterable: Ty, state: Ty, borrows: bool) Ty? {
    if !ty_copyable(self, state) {
        return Some(state)
    }
    if !own_is_place(fs.iterable) and borrows and !ty_copyable(self, iterable) {
        return Some(iterable)
    }
    return null
}

// The loop's release: `deinit` on what `iter_owned` named, recorded on the loop variable's node and
// run on every exit from the loop.
fn is_ref_ty(self: &Checker, t: Ty) bool {
    return ty_node(self, self.engine.resolve(t)) match {
        NRef(_) => true
        _ => false
    }
}

fn record_iter_release(self: &Checker, fs: &ForStmt, owned: Ty?) {
    if owned.is_none() {
        return
    }
    const state = owned.unwrap()
    let no_args: List(Ty) = list(0)
    defer no_args.deinit()
    const dp = receiver_pick(self, "deinit", state, &no_args, fs.span, fs.var_span)
    if dp.is_none() {
        push_diag_e(
            self,
            fs.span,
            E_NO_OVERLOAD,
            from_view("the loop owns its iterator, which is not copyable and declares no `deinit`"),
        )
        return
    }
    const d = dp.unwrap()
    self.results.record_operator(
        self.node_of(fs.var_span),
        ResolvedOperator {
            function_id = d.id,
            negate_result = false,
            cmp_derived_op = null,
            is_ref_form = false,
            spec_id = null,
            lhs_hops = 0u32,
            rhs_hops = 0u32,
        },
    )
    note_pending(self, fs.var_span, true, &d)
}

fn check_range_bounds(self: &Checker, r: &RangeExpr) Ty {
    return unify_range_bounds(self, r.start, r.end, r.span)
}

fn check_range_bounds(self: &Checker, r: &RangePattern) Ty {
    return unify_range_bounds(self, r.start, r.end, r.span)
}

// Both bounds of a range share one type; that is its element type. The expression and pattern forms
// are separate AST types with identical shape (the grammar restricts where each may appear), so
// both funnel here.
fn unify_range_bounds(self: &Checker, start: &Expr?, end: &Expr?, span: SourceSpan) Ty {
    let elem = self.engine.fresh_var()
    start match {
        Some(e) => { unify_expected(self, check_expr(self, e), elem, E_TYPE_MISMATCH, span) }
        None => {}
    }
    end match {
        Some(e) => { unify_expected(self, check_expr(self, e), elem, E_TYPE_MISMATCH, span) }
        None => {}
    }
    return elem
}

// Statement-context if: branches unify only when they agree - a mismatch is silently void, never an
// error.
fn check_if_stmt(self: &Checker, if_expr: &IfExpr) {
    let _c = check_expr(self, if_expr.condition)
    let then_ty = check_block(self, if_expr.then_branch)
    if_expr.else_branch match {
        NoElse => {}
        Block(b) => {
            let else_ty = check_block(self, b)
            let probe = self.engine.try_unify(then_ty, else_ty)
            if probe.is_ok() {
                let _o = self.engine.unify(then_ty, else_ty)
            }
        }
        If(nested) => check_if_stmt(self, nested)
    }
}

fn check_let(self: &Checker, ls: &LetStmt) {
    // A same-scope re-declaration is legal but hides the earlier binding for the rest of the block;
    // `_`-prefixed names opt out (W1002, reference parity).
    if self.env.exists_in_current(ls.name) and !starts_with_underscore(ls.name) {
        push_diag_w(
            self,
            ls.span,
            W_SAME_SCOPE_SHADOW,
            $"`{ls.name}` shadows an earlier declaration in the same scope",
        )
    }
    // `let x = []` has nothing to fix the element type (E2026). An annotated `let xs: [i32; 0] =
    // []` is fine - the annotation pins it.
    if ls.type_annotation.is_none() {
        ls.init match {
            Some(e) => {
                if is_empty_array_literal(e) {
                    push_diag_e(
                        self,
                        ls.span,
                        E_EMPTY_ARRAY,
                        $"cannot infer the element type of the empty array `{ls.name}` is bound to",
                    )
                }
            }
            None => {}
        }
    }
    // `const x: i32` with no initializer can never be given one (E2039).
    if ls.is_const and ls.init.is_none() {
        push_diag_e(self, ls.span, E_CONST_NO_INIT, $"`const {ls.name}` must have an initializer")
    }
    let annotated = ls.type_annotation match {
        Some(t) => Some(resolve_type_expr(self, t))
        None => null
    }
    let inferred = ls.init match {
        Some(e) => Some(check_expr(self, e, annotated))
        None => null
    }
    let bound_ty = annotated match {
        Some(a) => {
            inferred match {
                Some(i) => {
                    unify_expected(self, i, a, E_TYPE_MISMATCH, ls.span)
                    a
                }
                None => a
            }
        }
        None => inferred match {
            Some(i) => i
            None => self.engine.fresh_var()
        }
    }
    // Lowering reads the binding's type off the statement node. The name token's node carries the
    // same type so a cursor on the name resolves (hover, inlay hints), and it is the binding's
    // `decl` so goto-definition on a read lands on the name, not the whole statement.
    self.results.record_type(self.node_of(ls.span), bound_ty)
    const name_node = self.node_of(ls.name_span)
    self.results.record_type(name_node, bound_ty)
    self.env.bind(
        ls.name,
        Binding {
            scheme = mono(bound_ty),
            decl = name_node,
            is_const = ls.is_const,
            is_type_param = false,
        },
    )
}

fn is_empty_array_literal(e: &Expr) bool {
    return e.* match {
        ArrayLit(al) => al.kind match {
            Elements(es) => es.len == 0
            _ => false
        }
        _ => false
    }
}

fn starts_with_underscore(name: String) bool {
    return name.len > 0 and name[0] == '_'
}

fn unify_expected(self: &Checker, inferred: Ty, annotated: Ty, code: String, span: SourceSpan) {
    const o = self.engine.unify(inferred, annotated)
    report_unify(self, &o, code, span)
}

// Join two branch types: match arms, if/else branches.
//
// Distinct from `unify_expected`, where one side is the slot and the other flows into it. Here
// neither side is the slot, so coercion is tried in both directions and the *result* is the joined
// type rather than one of the inputs. Without that, arm order decides the answer: `T` then `null`
// would fix the type at `T` and reject the `null`.
//
// `Never` is the identity - it takes the other side - which is how a diverging arm stays out of the
// join entirely.
fn join_types(self: &Checker, a: Ty, b: Ty, code: String, span: SourceSpan) Ty {
    let forward = self.engine.try_unify(a, b).is_ok()
    const o = if forward {
        self.engine.unify(a, b)
    } else {
        self.engine.unify(b, a)
    }
    report_unify(self, &o, code, span)
    return o match {
        Unified(u) => u.ty
        // The branches have no common type, and `report_unify` has just said so. `Error` is the
        // engine's poison: it absorbs into anything silently, so the one diagnostic does not
        // cascade into every later use of the result. Returning one of the operands instead would
        // carry a type the program does not actually have.
        _ => TY_ERROR
    }
}

fn check_return(self: &Checker, rs: &ReturnStmt) {
    let frame_idx = self.fn_stack.len
    if frame_idx == 0 {
        return
    }
    let frame = &self.fn_stack[frame_idx - 1]
    rs.value match {
        Some(e) => {
            let v = check_expr(self, e)
            unify_expected(self, v, frame.return_ty, E_RETURN_MISMATCH, rs.span)
        }
        None => {
            const o = self.engine.unify(TY_VOID, frame.return_ty)
            report_unify(self, &o, E_RETURN_MISMATCH, rs.span)
        }
    }
}

// Both operands of a binary operator share one type - shifts excepted, since a shift count need not
// match the value's width. Comparisons and the logical connectives produce `bool`; everything else
// produces the operand type.
//
// Unifying the operands is also right for the `op_add(self: T, other: T) T` overload shape, so user
// types are no worse off than before. What it replaces is a bare fresh var, which let `1 + "hello"`
// type-check clean and left every arithmetic node unconstrained - so lowering saw no primitive and
// emitted the default width, compiling `i32` arithmetic at 64 bits.
//
// ponytail: operator *overload resolution* (looking `op_add` up in the function registry) still is
// not done here; the operand types are constrained, the callee is not.
fn check_binary(self: &Checker, bin: &BinaryExpr) Ty {
    let lhs = check_expr(self, bin.lhs)
    let rhs = check_expr(self, bin.rhs)
    return bin.op match {
        Eq => comparison(self, bin, lhs, rhs)
        Ne => comparison(self, bin, lhs, rhs)
        Lt => comparison(self, bin, lhs, rhs)
        Gt => comparison(self, bin, lhs, rhs)
        Le => comparison(self, bin, lhs, rhs)
        Ge => comparison(self, bin, lhs, rhs)
        And => logical_result(self, lhs, rhs, bin.span)
        Or => logical_result(self, lhs, rhs, bin.span)
        // Shifts land on the arith rule too: the count unifies with the shifted value's type,
        // matching the reference's unified result for Shl/Shr/UShr - and pinning a literal count.
        Shl => shift(self, bin, lhs, rhs)
        Shr => shift(self, bin, lhs, rhs)
        UShr => shift(self, bin, lhs, rhs)
        _ => arithmetic(self, bin, lhs, rhs)
    }
}

// A shift whose count is a literal must keep the count inside the shifted operand's width: the
// result has the left operand's type, so a wider count leaves nothing of the value (E2121). Checked
// when inference has already pinned the left operand to an integer primitive; a shift whose left
// operand is still open here (a bare literal, a generic) goes unchecked - the reference compiler
// sweeps those post-inference (see known-issues, checker parity).
fn shift(self: &Checker, bin: &BinaryExpr, lhs: Ty, rhs: Ty) Ty {
    const lit = bin.rhs.* match {
        Lit(le) => le.value match {
            Int(il) => Some(il)
            _ => null
        }
        _ => null
    }
    if lit.is_none() {
        return arithmetic(self, bin, lhs, rhs)
    }

    const p = ty_node(self, self.engine.resolve(lhs)) match {
        NPrim(pk) => pk
        _ => return arithmetic(self, bin, lhs, rhs)
    }
    if !is_integer(p) {
        return arithmetic(self, bin, lhs, rhs)
    }

    const width = prim_bit_width(p)
    const amount = parse_int_magnitude(lit.unwrap().text)
    if amount.is_some() and amount.unwrap() >= width as u64 {
        push_diag_e(
            self,
            lit.unwrap().span,
            E_SHIFT_RANGE,
            $"Shift amount `{lit.unwrap().text}` is out of range for `{prim_name(p)}` (0..{width - 1})",
        )
    }
    return arithmetic(self, bin, lhs, rhs)
}

fn prim_bit_width(p: PrimitiveKind) u32 {
    return p match {
        I8 => 8u32, U8 => 8u32
        I16 => 16u32, U16 => 16u32
        I32 => 32u32, U32 => 32u32
        _ => 64u32
    }
}

// The arithmetic half of the operator ladder: `a + b` over nominal
// operands dispatches to the user's `op_add`/`op_sub`/… exactly as a
// comparison dispatches to `op_eq`. Primitives (and operands inference has not pinned yet) keep the
// builtin hardware path - probing the registry for them would let a user `op_add(i32, i32)` capture
// every integer addition in the program.
fn arithmetic(self: &Checker, bin: &BinaryExpr, lhs: Ty, rhs: Ty) Ty {
    let l = self.engine.resolve(lhs)
    let r = self.engine.resolve(rhs)
    let l_nom = ty_node(self, l) match { NNominal(_) => true, _ => false }
    let r_nom = ty_node(self, r) match { NNominal(_) => true, _ => false }
    if !l_nom or !r_nom {
        return arith_result(self, lhs, rhs, bin.span)
    }

    let name = arith_op_name(bin.op)
    if name.len == 0 {
        return arith_result(self, lhs, rhs, bin.span)
    }
    return binary_dispatch(self, bin, l, r, false) match {
        Some(t) => t
        None => {
            push_diag_e(
                self,
                bin.span,
                E_OP_NO_IMPL,
                $"no `{name}` implementation for these operand types",
            )
            lhs
        }
    }
}

// The `op_*` function an arithmetic/bitwise operator desugars to (spec 4.4). Empty for the
// operators that have no user-overloadable form (`and`/`or` short-circuit and never reach here).
fn arith_op_name(op: BinaryOp) String {
    return op match {
        Add => "op_add"
        Sub => "op_sub"
        Mul => "op_mul"
        Div => "op_div"
        Mod => "op_mod"
        BitAnd => "op_band"
        BitOr => "op_bor"
        BitXor => "op_bxor"
        Shl => "op_shl"
        Shr => "op_shr"
        UShr => "op_ushr"
        _ => ""
    }
}

fn compare_result(self: &Checker, lhs: Ty, rhs: Ty, span: SourceSpan) Ty {
    unify_either(self, lhs, rhs, span)
    return prim_of(PrimitiveKind.Bool)
}

// A comparison over nominal operands dispatches to a user operator function (M11), mirroring the
// reference's ladder:
//
//   1. primitives (and unresolved operands) keep the builtin compare -
//      the hardware path, and the recursion-breaker for `op_cmp(i32,i32)`;
//   2. `==`/`!=` on a payload-less enum is a builtin tag compare
//      (structural equality for free - lowering detects the shape);
//   3. the direct operator fn (`op_eq`, `op_lt`, ...);
//   4. derived: `!=` as negated `op_eq` (and `==` as negated `op_ne`),
//      then any comparison from `op_cmp` against Ord's fixed tags.
//
// The winner lands on the node as a `ResolvedOperator` - the seam indexing already uses - so
// lowering emits a call, not FIR arithmetic over addresses. Value-form operands only: every in-tree
// operator fn takes its operands by value.
fn comparison(self: &Checker, bin: &BinaryExpr, lhs: Ty, rhs: Ty) Ty {
    let l = self.engine.resolve(lhs)
    let r = self.engine.resolve(rhs)
    let l_nom = ty_node(self, l) match { NNominal(_) => true, _ => false }
    let r_nom = ty_node(self, r) match { NNominal(_) => true, _ => false }
    if !l_nom or !r_nom {
        return compare_result(self, lhs, rhs, bin.span)
    }

    let is_eq_shape = bin.op match { Eq => true, Ne => true, _ => false }
    if is_eq_shape and payloadless_enum(self, l) and payloadless_enum(self, r) {
        return compare_result(self, lhs, rhs, bin.span)
    }

    const dispatched = binary_dispatch(self, bin, l, r, true)
    if dispatched.is_some() {
        return dispatched.unwrap()
    }

    // Both operands are nominals and nothing in the ladder matched, as written or through
    // `op_deref` - comparing them would be a bitwise compare of addresses. E2017.
    push_diag_e(
        self,
        bin.span,
        E_OP_NO_IMPL,
        $"no `{direct_op_name(bin.op)}` (or `op_cmp`) implementation for these operand types",
    )
    return prim_of(PrimitiveKind.Bool)
}

// One rung of the operator ladder that matched.
type OpMatch = struct {
    pick: OverloadPick
    negate: bool
    derived: BinaryOpDerived?
    ret: Ty
}

// The ladder over one pair of operand types: for a comparison the direct function, then the negated
// opposite for `==`/`!=`, then `op_cmp`; for arithmetic the one `op_*` function. One matched
// operator: the pick moves in, and its return type is read on the way.
fn op_match_of(p: move OverloadPick, negate: bool, derived: BinaryOpDerived?) OpMatch {
    const ret = p.ret
    return OpMatch { pick = move p, negate = negate, derived = derived, ret = ret }
}

fn operator_match(
    self: &Checker,
    op: BinaryOp,
    span: SourceSpan,
    l: Ty,
    r: Ty,
    is_cmp: bool,
) OpMatch? {
    if !is_cmp {
        const pick = operator_pick_2(self, arith_op_name(op), l, r, span)
        return pick match {
            Some(p) => Some(op_match_of(p, false, null))
            None => null
        }
    }
    const direct = operator_pick_2(self, direct_op_name(op), l, r, span)
    if direct.is_some() {
        const p = direct.unwrap()
        return Some(op_match_of(p, false, null))
    }
    const is_eq_shape = op match { Eq => true, Ne => true, _ => false }
    if is_eq_shape {
        const opposite = op match { Eq => "op_ne", _ => "op_eq" }
        const neg = operator_pick_2(self, opposite, l, r, span)
        if neg.is_some() {
            const p = neg.unwrap()
            return Some(op_match_of(p, true, null))
        }
    }
    const cmp = operator_pick_2(self, "op_cmp", l, r, span)
    return cmp match {
        Some(p) => Some(OpMatch {
            pick = move p,
            negate = false,
            derived = Some(bod_of(op)),
            ret = prim_of(PrimitiveKind.Bool),
        })
        None => null

    }
}

// Resolves a binary operator over its operands as written, then with either operand peeled through
// its `op_deref` chain: fewest hops first, the left side first at a tie. Only nominal operand pairs
// dispatch, peeled or not - a wrapped primitive never reaches an operator function or a builtin.
// Records the winner and its hops on the operator node and returns the expression's type; null when
// nothing matched.
fn binary_dispatch(self: &Checker, bin: &BinaryExpr, l: Ty, r: Ty, is_cmp: bool) Ty? {
    const direct = operator_match(self, bin.op, bin.span, l, r, is_cmp)
    let lc: List(OverloadPick) = list(0)
    defer lc.deinit()
    let rc: List(OverloadPick) = list(0)
    defer rc.deinit()
    if direct.is_some() {
        const __direct_v = direct.unwrap()
        return Some(commit_binary(self, bin, &__direct_v, &lc, 0usize, &rc, 0usize))
    }
    let lt: List(Ty) = list(0)
    defer lt.deinit()
    let rt: List(Ty) = list(0)
    defer rt.deinit()
    operand_chain(self, l, bin.span, &lc, &lt)
    operand_chain(self, r, bin.span, &rc, &rt)
    for total in 1..(lc.len + rc.len + 1) {
        let li = if total < lc.len { total } else { lc.len }
        loop {
            const ri = total - li
            if ri <= rc.len {
                const lty = if li == 0 { l } else { lt[li - 1] }
                const rty = if ri == 0 { r } else { rt[ri - 1] }
                const m = if both_nominal(self, lty, rty) {
                    operator_match(self, bin.op, bin.span, lty, rty, is_cmp)
                } else {
                    null
                }
                if m.is_some() {
                    const __m_v = m.unwrap()
                    return Some(commit_binary(self, bin, &__m_v, &lc, li, &rc, ri))
                }
            }
            if li == 0 {
                break
            }
            li = li - 1
        }
    }
    return null
}

// Operator functions are consulted for nominal operands only, as written or peeled: a primitive
// pair keeps the builtin operation, which no registry entry may capture.
fn both_nominal(self: &Checker, l: Ty, r: Ty) bool {
    const l_nom = ty_node(self, l) match { NNominal(_) => true, _ => false }
    const r_nom = ty_node(self, r) match { NNominal(_) => true, _ => false }
    return l_nom and r_nom
}

// A nominal operand's `op_deref` chain: `picks[k]` is hop k+1, `tys[k]` the operand's type after
// it. Stops at the first type that is not a nominal or has no `op_deref`.
fn operand_chain(
    self: &Checker,
    t: Ty,
    span: SourceSpan,
    picks: &List(OverloadPick),
    tys: &List(Ty),
) {
    let vis = fn_visibility(self)
    defer vis.deinit()
    const dcands = deref_candidates(self, &vis)
    if dcands.is_none() {
        return
    }
    let dc = dcands.unwrap()
    defer dc.deinit()
    let current = t
    while picks.len < 10 {
        const is_nominal = ty_node(self, current) match { NNominal(_) => true, _ => false }
        if !is_nominal {
            return
        }
        let dargs: List(Ty) = list(1)
        dargs.push(self.engine.mk_ref(current))
        const dpick = resolve_overload(self, &dc, &dargs, span)
        dargs.deinit()
        if dpick.is_none() {
            return
        }
        const hop = dpick.unwrap()
        const inner = ty_node(self, self.engine.resolve(hop.ret)) match {
            NRef(i) => self.engine.resolve(i)
            _ => return
        }
        picks.push(hop)
        tys.push(inner)
        current = inner
    }
}

// Records the operator and the operand hops it resolved through: the left operand's first `li`
// hops, then the right operand's first `ri`, on the operator node's deref chain. Returns the
// expression's type.
fn commit_binary(
    self: &Checker,
    bin: &BinaryExpr,
    m: &OpMatch,
    lc: &List(OverloadPick),
    li: usize,
    rc: &List(OverloadPick),
    ri: usize,
) Ty {
    const node = self.node_of(bin.span)
    if li + ri > 0 {
        let targets: List(ResolvedTarget) = list(li + ri)
        for i in 0..li {
            targets.push(ResolvedTarget.RtFunction(lc[i].id))
        }
        for i in 0..ri {
            targets.push(ResolvedTarget.RtFunction(rc[i].id))
        }
        self.results.record_receiver_deref(node, targets)
        for i in 0..li {
            note_pending(self, bin.span, false, &lc[i], Some(i))
        }
        for i in 0..ri {
            note_pending(self, bin.span, false, &rc[i], Some(li + i))
        }
    }
    self.results.record_operator(
        node,
        ResolvedOperator {
            function_id = m.pick.id,
            negate_result = m.negate,
            cmp_derived_op = m.derived,
            is_ref_form = false,
            spec_id = null,
            lhs_hops = li as u32,
            rhs_hops = ri as u32,
        },
    )
    note_pending(self, bin.span, true, &m.pick)
    return m.ret
}

fn direct_op_name(op: BinaryOp) String {
    return op match {
        Eq => "op_eq"
        Ne => "op_ne"
        Lt => "op_lt"
        Gt => "op_gt"
        Le => "op_le"
        _ => "op_ge"
    }
}

fn bod_of(op: BinaryOp) BinaryOpDerived {
    return op match {
        Eq => BinaryOpDerived.BodEq
        Ne => BinaryOpDerived.BodNe
        Lt => BinaryOpDerived.BodLt
        Gt => BinaryOpDerived.BodGt
        Le => BinaryOpDerived.BodLe
        _ => BinaryOpDerived.BodGe
    }
}

fn operator_pick_2(self: &Checker, name: String, l: Ty, r: Ty, span: SourceSpan) OverloadPick? {
    let args = list(2)
    args.push(l)
    args.push(r)
    let pick = operator_pick(self, name, &args, span)
    args.deinit()
    return pick
}

fn payloadless_enum(self: &Checker, ty: Ty) bool {
    return ty_node(self, ty) match {
        NNominal(nn) => enum_payloadless(&self.nominals, nn.id)
        _ => false
    }
}

// `a op b` imposes no direction, but the coercion ladder has one: a `char` coerces to `u8`, not the
// reverse. Probe both ways before reporting, so `c == 'h'` with `c: u8` is accepted exactly as `'h'
// == c` is.
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
    let b = prim_of(PrimitiveKind.Bool)
    const o1 = self.engine.unify(lhs, b)
    report_unify(self, &o1, E_TYPE_MISMATCH, span)
    const o2 = self.engine.unify(rhs, b)
    report_unify(self, &o2, E_TYPE_MISMATCH, span)
    return b
}

// Pointer arithmetic: `p + n` and `p - n` offset a reference by an integer count, so the operands
// deliberately do NOT unify and the result is the pointer type. Unifying them here is what made
// `s.ptr + idx` - the shape every slice and hash routine in the stdlib uses - fail to check.
//
// ponytail: `p - q` between two references should yield an integer distance, not a pointer. It
// currently yields the pointer type. Nothing in the corpus does it; fix when something does.
fn arith_result(self: &Checker, lhs: Ty, rhs: Ty, span: SourceSpan) Ty {
    let lhs_is_ref = ty_node(self, self.engine.resolve(lhs)) match { NRef(_) => true, _ => false }
    if lhs_is_ref {
        return lhs
    }
    unify_either(self, lhs, rhs, span)
    return lhs
}

fn check_call(self: &Checker, call: &CallExpr, expected: Ty? = null) Ty {
    let pos_tys = list(call.args.len)
    let pos_exprs: List(&Expr) = list(call.args.len)
    // Filled as locals, then moved into the bundle: growing a list THROUGH a struct field of a
    // local copies the header and loses the push (docs/known-issues.md, two-hop mutation).
    let nnames: List(String) = list(0)
    let ntys: List(Ty) = list(0)
    let nvalues: List(&Expr) = list(0)
    for &a in call.args {
        a.* match {
            Positional(e) => {
                pos_tys.push(check_expr(self, e))
                pos_exprs.push(e)
            }
            Named(n) => {
                ntys.push(check_expr(self, n.value))
                nnames.push(n.name)
                nvalues.push(n.value)
            }
        }
    }
    let named = NamedArgs { names = move nnames, tys = move ntys, values = move nvalues }
    let named_seen = named.names.len > 0
    // Variant constructors take no named arguments, so their presence rules the variant
    // interpretation out before any lookup.
    if !named_seen {
        let vt = variant_call(self, call, &pos_tys)
        if vt.is_some() {
            pos_tys.deinit()
            pos_exprs.deinit()
            named.deinit()
            return vt.unwrap()
        }
        let ti = call.callee.* match {
            Identifier(ide) => type_instantiation_call(self, &ide, &pos_tys)
            _ => null
        }
        if ti.is_some() {
            pos_tys.deinit()
            pos_exprs.deinit()
            named.deinit()
            return ti.unwrap()
        }
    }
    report_argument_moves(self, call)
    let nref: &NamedArgs? = null
    if named_seen {
        nref = Some(&named)
    }
    let rc = resolve_call(self, call, &pos_tys, &pos_exprs, nref, expected)
    if rc.is_some() {
        pos_tys.deinit()
        pos_exprs.deinit()
        named.deinit()
        return rc.unwrap()
    }
    pos_tys.deinit()
    pos_exprs.deinit()
    named.deinit()
    let _r = check_expr(self, call.callee)
    return self.engine.fresh_var()
}

// Rule 6 of RFC-033: a call site carries no ownership marker, in argument or receiver position. The
// parameter says whether the call takes ownership. Variant payloads are not arguments: they keep
// `move` with struct literal fields.
fn report_argument_moves(self: &Checker, call: &CallExpr) {
    call.callee.* match {
        MemberAccess(ma) => report_argument_move(self, ma.receiver)
        _ => {}
    }
    for &a in call.args {
        a.* match {
            Positional(e) => report_argument_move(self, e)
            Named(n) => report_argument_move(self, n.value)
        }
    }
}

fn report_argument_move(self: &Checker, e: &Expr) {
    e.* match {
        Move(m) => push_diag_e(
            self,
            m.span,
            E_MOVE_IN_ARGUMENT,
            from_view(
                "`move` in argument position: the parameter declares whether the call takes ownership - remove it",
            ),
        )
        _ => {}
    }
}

// The `name = value` slots of one call site, split out of `call.args`. Parallel lists: `names[i]`
// is the parameter the value binds to, `tys[i]` its checked type, `values[i]` a shallow copy of the
// argument expression (shared AST children) for the recorded argument list.
type NamedArgs = struct {
    names: List(String)
    tys: List(Ty)
    values: List(&Expr)
}

pub fn deinit(self: move NamedArgs) {
    self.names.deinit()
    self.tys.deinit()
    self.values.deinit()
}

// Each named argument's parameter index in candidate `c`, or null when a name is not one of `c`'s
// parameters (the candidate is out). Parameters below `ufcs_offset` are the prepended receiver and
// cannot be named.
fn named_param_slots(
    self: &Checker,
    c: &FunctionScheme,
    named: &NamedArgs,
    ufcs_offset: usize,
) List(usize)? {
    let dp = self.fn_decl_params.get_ref(c.id)
    if dp.is_none() {
        return null
    }
    let decl = &dp.unwrap().params
    let out: List(usize) = list(named.names.len)
    for i in 0..named.names.len {
        let found: usize? = null
        for p in ufcs_offset..decl.len {
            if found.is_none() and decl[p].name == named.names[i] {
                found = Some(p)
            }
        }
        if found.is_none() {
            out.deinit()
            return null
        }
        out.push(found.unwrap())
    }
    return Some(move out)
}

// Resolve a call to its target: registry overloads (direct, or UFCS with the receiver as first
// argument), a Func-typed struct field, or a Func-typed value. Some(ty) is the call's type -
// failures inside report a diagnostic and yield a fresh var so inference continues. Null means the
// callee shape has no resolution path; the caller falls back.
fn resolve_call(
    self: &Checker,
    call: &CallExpr,
    arg_tys: &List(Ty),
    pos_exprs: &List(&Expr),
    named: &NamedArgs? = null,
    expected: Ty? = null,
) Ty? {
    return call.callee.* match {
        Identifier(ide) => resolve_direct_call(
            self,
            call,
            &ide,
            arg_tys,
            pos_exprs,
            named,
            expected,
        )
        MemberAccess(ma) => resolve_method_call(self, call, &ma, arg_tys, pos_exprs, named)
        _ => null
    }
}

// `foo(args)` - registry overloads win over value bindings, mirroring the reference checker's call
// order; a value binding of function type is the fallback.
fn resolve_direct_call(
    self: &Checker,
    call: &CallExpr,
    ide: &IdentifierExpr,
    arg_tys: &List(Ty),
    pos_exprs: &List(&Expr),
    named: &NamedArgs? = null,
    expected: Ty? = null,
) Ty? {
    let vis = fn_visibility(self)
    defer vis.deinit()
    let cands = self.functions.lookup(ide.name, &vis) match {
        FnLookFound(c) => Some(move c)
        _ => null
    }
    if cands.is_some() {
        let candidates = cands.unwrap()
        self.overload_deferred = false
        let chain: List(OverloadPick) = list(0)
        defer chain.deinit()
        let ctx = PeelCtx { vis = &vis, chain = &chain }
        let spans = arg_span_list(self, pos_exprs, null)
        defer spans.deinit()
        let pick = resolve_overload(
            self,
            &candidates,
            arg_tys,
            call.span,
            null,
            named,
            0usize,
            true,
            Some(&ctx),
            Some(&spans),
            expected,
        )
        candidates.deinit()
        if pick.is_none() and self.overload_deferred {
            self.overload_deferred = false
            return Some(park_call(self, call, ide.name, arg_tys, pos_exprs, 0usize, null))
        }
        if pick.is_none() and closure_arg_hint(self, arg_tys, call.span) {
            return Some(self.engine.fresh_var())
        }
        return Some(commit_pick(
            self,
            pick,
            ide.name,
            arg_tys.len,
            call.span,
            0usize,
            pos_exprs,
            named,
        ))
    }
    // A named argument cannot address a parameter of a function VALUE (no declaration, so no
    // parameter names) - leave the call for the caller's fallback rather than dropping the names
    // silently.
    if named.is_some() {
        return null
    }
    let callee_ty = check_expr(self, call.callee)
    return Some(indirect_call(self, callee_ty, arg_tys, call.span))
}

// `recv.method(args)` - a Func-typed struct field dispatches directly (the vtable pattern wins over
// UFCS, as in the reference checker); otherwise the receiver becomes the first argument of a
// registry overload, retried with the receiver adapted between value and reference forms.
fn resolve_method_call(
    self: &Checker,
    call: &CallExpr,
    ma: &MemberAccessExpr,
    arg_tys: &List(Ty),
    pos_exprs: &List(&Expr),
    named: &NamedArgs? = null,
) Ty? {
    let recv_ty = check_expr(self, ma.receiver)

    // A field holding a function value has no parameter names, so a named-argument call never
    // dispatches through it (reference parity: "named arguments are not supported for
    // indirect/field calls").
    if named.is_none() {
        let fc = field_call(self, recv_ty, ma.member, arg_tys, call.span, self.node_of(ma.span))
        if fc.is_some() {
            return fc
        }
    }

    let vis = fn_visibility(self)
    defer vis.deinit()
    let cands = self.functions.lookup(ma.member, &vis) match {
        FnLookFound(c) => Some(move c)
        _ => null
    }
    if cands.is_none() {
        // `fba.allocator()` where `allocator` is a plain field: the name exists on the receiver, it
        // is just not callable (E2011). Only a name that is nowhere at all is "unresolved" (E2004).
        if struct_field_lookup(self, recv_ty, ma.member).is_some() {
            push_diag_e(
                self,
                call.span,
                E_NO_OVERLOAD,
                $"`{ma.member}` is a field of this type, not a callable method",
            )
        } else {
            push_diag_e(self, call.span, E_UNKNOWN_IDENT, $"unresolved function `{ma.member}`")
        }
        return Some(self.engine.fresh_var())
    }
    let candidates = cands.unwrap()

    // A still-unbound receiver (a lambda parameter the callee's instantiation pins, a parked member
    // access) cannot arbitrate an overload set, and even a lone candidate would bind it to the
    // parameter's shape - `&Option($T)` for a value the call should auto-reference. Park the call:
    // it resolves after the body's drain, when the receiver is known.
    if self.engine.is_var(self.engine.resolve(recv_ty)) {
        candidates.deinit()
        let full: List(Ty) = list(arg_tys.len + 1)
        full.push(recv_ty)
        full.push_all(arg_tys.as_slice())
        return Some(park_call(
            self,
            call,
            ma.member,
            &full,
            pos_exprs,
            1usize,
            Some(self.engine.mk_ref(recv_ty)),
        ))
    }

    // Receiver adaptation: a value receiver also matches `&T` overloads and a reference receiver
    // also matches value overloads. The adapted shape competes inside the same resolution (see
    // resolve_overload) rather than as a fallback pass.
    let r = self.engine.resolve(recv_ty)
    let adapted = ty_node(self, r) match {
        NRef(inner) => inner
        _ => self.engine.mk_ref(r)
    }
    // The receiver's `op_deref` targets compete in that same set, as more receiver shapes.
    let chain: List(OverloadPick) = list(0)
    defer chain.deinit()
    let ctx = PeelCtx { vis = &vis, chain = &chain }
    self.overload_deferred = false
    let spans = arg_span_list(self, pos_exprs, Some(expr_span(ma.receiver)))
    defer spans.deinit()
    let pick = receiver_overload(
        self,
        &candidates,
        recv_ty,
        arg_tys,
        call.span,
        Some(adapted),
        named,
        Some(&ctx),
        Some(&spans),
    )
    if pick.is_some() {
        commit_deref_chain(self, &chain, pick_hops(&pick), call.span)
    }
    candidates.deinit()
    if pick.is_none() and self.overload_deferred {
        self.overload_deferred = false
        let full: List(Ty) = list(arg_tys.len + 1)
        full.push(recv_ty)
        full.push_all(arg_tys.as_slice())
        return Some(park_call(self, call, ma.member, &full, pos_exprs, 1usize, Some(adapted)))
    }
    if pick.is_none() and closure_arg_hint(self, arg_tys, call.span) {
        return Some(self.engine.fresh_var())
    }
    return Some(commit_pick(
        self,
        pick,
        ma.member,
        arg_tys.len,
        call.span,
        1usize,
        pos_exprs,
        named,
        Some(recv_ty),
    ))
}

// One overload-resolution attempt with `recv` prepended as the first argument. `alt_recv` is its
// adapted value <-> &T shape, competing in the same ranked set.
fn receiver_overload(
    self: &Checker,
    candidates: &List(&FunctionScheme),
    recv: Ty,
    arg_tys: &List(Ty),
    span: SourceSpan,
    alt_recv: Ty? = null,
    named: &NamedArgs? = null,
    peel: &PeelCtx? = null,
    arg_spans: &List(SourceSpan)? = null,
) OverloadPick? {
    let full = list(arg_tys.len + 1)
    full.push(recv)
    full.push_all(arg_tys.as_slice())
    let pick = resolve_overload(
        self,
        candidates,
        &full,
        span,
        alt_recv,
        named,
        1usize,
        false,
        peel,
        arg_spans,
    )
    full.deinit()
    return pick
}

// Resolves `name` as a method of `recv` with `extra` arguments, ranking every receiver shape in one
// set: as written, adapted between value and reference, and peeled through `op_deref`. The winner's
// hop chain is recorded on the node at `record_span` for lowering. The protocol operators
// (`op_index_ref`, `op_set_index`, `iter`) resolve through here, so `xs[i]` and `for x in xs`
// resolve exactly as `xs.op_index_ref(i)` and `xs.iter()` would.
//
// Returns null when nothing matches, without reporting: a caller that tries several names reports
// once at the end.
fn receiver_pick(
    self: &Checker,
    name: String,
    recv: Ty,
    extra: &List(Ty),
    span: SourceSpan,
    record_span: SourceSpan,
) OverloadPick? {
    let chain: List(OverloadPick) = list(0)
    defer chain.deinit()
    let pick = receiver_pick_into(self, name, recv, extra, span, &chain)
    if pick.is_some() {
        commit_deref_chain(self, &chain, pick_hops(&pick), record_span)
    }
    return pick
}

// `receiver_pick` without recording: whether `recv.name(extra...)` resolves, for a contract
// requirement (RFC-035). A by-value receiver is not adapted to a reference: `hash(self: Self)` met
// by a `hash(&$T)`, or by a blanket `hash($T)` at `T = &Self`, would hash the address. The pick's
// unifications are committed; the caller decides whether to keep them.
fn satisfy_pick(
    self: &Checker,
    name: String,
    recv: Ty,
    extra: &List(Ty),
    span: SourceSpan,
) OverloadPick? {
    let chain: List(OverloadPick) = list(0)
    defer chain.deinit()
    return receiver_pick_into(self, name, recv, extra, span, &chain, false)
}

// The resolution behind `receiver_pick`: the winner's `op_deref` hops land in `chain`.
fn receiver_pick_into(
    self: &Checker,
    name: String,
    recv: Ty,
    extra: &List(Ty),
    span: SourceSpan,
    chain: &List(OverloadPick),
    take_address: bool = true,
) OverloadPick? {
    let vis = fn_visibility(self)
    defer vis.deinit()
    let cands = self.functions.lookup(name, &vis) match {
        FnLookFound(c) => Some(move c)
        _ => null
    }
    if cands.is_none() {
        return null
    }
    let candidates = cands.unwrap()
    defer candidates.deinit()
    let r = self.engine.resolve(recv)
    let adapted: Ty? = ty_node(self, r) match {
        NRef(inner) => Some(inner)
        _ => if take_address { Some(self.engine.mk_ref(r)) } else { null }
    }
    let ctx = PeelCtx { vis = &vis, chain = chain }
    return receiver_overload(self, &candidates, recv, extra, span, adapted, null, Some(&ctx))
}

// The `op_deref` overloads visible to the current function, for `PeelCtx`; null when there are
// none, so `resolve_overload` skips the peel outright.
fn deref_candidates(self: &Checker, vis: &Visibility) List(&FunctionScheme)? {
    return self.functions.lookup("op_deref", vis) match {
        FnLookFound(c) => Some(move c)
        _ => null
    }
}

// Records the first `hops` entries of a winning deref chain on the node at `span`, for lowering to
// call each hop before the winner: one target per hop, outermost first, plus a pending
// specialization per generic hop (the drain rewrites that hop's entry to `RtSpecialized`, keyed by
// `deref_index`). Records nothing for zero hops.
fn commit_deref_chain(
    self: &Checker,
    chain: &List(OverloadPick),
    hops: usize,
    span: SourceSpan,
    on_arg: bool = false,
) {
    if hops == 0 {
        return
    }
    let targets: List(ResolvedTarget) = list(hops)
    for i in 0..hops {
        targets.push(ResolvedTarget.RtFunction(chain[i].id))
    }
    // Recorded BEFORE the pendings are noted: a pick that instantiates immediately rewrites its hop
    // through `update_receiver_deref`, which needs the chain to already be there.
    if on_arg {
        self.results.record_arg_deref(self.node_of(span), targets)
    } else {
        self.results.record_receiver_deref(self.node_of(span), targets)
    }
    for i in 0..hops {
        note_pending(self, span, false, &chain[i], Some(i), on_arg)
    }
}

// A committed pick of a generic overload becomes a pending specialization - drained once the
// enclosing body's inference has settled (M10). `is_operator` selects which table the drain
// rewrites: `resolved_ops` for operator nodes, `resolved_targets` for calls.
fn note_pending(
    self: &Checker,
    span: SourceSpan,
    is_operator: bool,
    pick: &OverloadPick,
    deref_index: usize? = null,
    deref_on_arg: bool = false,
) {
    if pick.inst.is_none() {
        return
    }
    // The pick is lent, so the pending copy takes its own tables.
    let inst = pick.inst.unwrap_ref()
    let binds: Dict(VarId, Ty) = dict(inst.tp_binds.len())
    for e in inst.tp_binds {
        binds.set(e.key, e.value)
    }
    let inst_params: List(Ty) = list(inst.params.len)
    inst_params.push_all(inst.params.as_slice())
    let p = PendingSpec {
        span = span,
        is_operator = is_operator,
        deref_index = deref_index,
        deref_on_arg = deref_on_arg,
        function_id = pick.id,
        tp_binds = move binds,
        inst_params = move inst_params,
        inst_ret = inst.ret,
        caller_module = self.current_module.unwrap(),
        from_parked = self.resolving_parked,
    }
    // Parked, not instantiated here: the body scope's drain runs it once the enclosing inference
    // has settled. Instantiating EAGERLY at the call - which is what the reference does, and what
    // would settle a return-only `$U` before the next overload resolution sees it - was tried twice
    // and destabilises inference: re-entering the checker mid-expression nests a generalisation
    // level inside the caller's, and unrelated `xs.push(v)` arguments start typing as `Type(?)`.
    // See docs/known-issues.md §"return-only type parameters".
    self.pending_specs.push(p)
}

// Record the winner on the call node and return its instantiated return type; report when no
// overload matched. `recv_extra` is 1 when a UFCS receiver was prepended to the argument list (it
// counts toward the winner's parameter arity but not toward `n_args`, which feeds the user-facing
// diagnostic). `recv` is that receiver's type, and names it in the failure - which method is
// missing matters far less than which type is missing it.
fn commit_pick(
    self: &Checker,
    pick: move OverloadPick?,
    name: String,
    n_args: usize,
    span: SourceSpan,
    recv_extra: usize,
    pos_exprs: &List(&Expr),
    named: &NamedArgs?,
    recv: Ty? = null,
) Ty {
    return pick match {
        Some(p) => {
            self.results.record_target(self.node_of(span), ResolvedTarget.RtFunction(p.id))
            if p.adapt.is_some() {
                self.results.record_receiver_adapt(self.node_of(span), p.adapt.unwrap())
            }
            warn_deprecated_call(self, p.id, name, span)
            check_consuming_receiver(self, &p, name, recv, span)
            note_pending(self, span, false, &p)
            // The AST's argument order is the call's argument order except when names select
            // parameters or a variadic tail packs; those two record a complete list instead.
            if named.is_some() or pick_is_variadic(self, &p) {
                materialize_arg_list(self, &p, pos_exprs, named, recv_extra, span)
            } else {
                materialize_default_args(self, &p, n_args + recv_extra, span)
            }
            const ret = p.ret
            p.deinit()
            ret
        }
        None => {
            let sb = string_builder(96)
            sb.append($"no matching overload for `{name}` with {n_args} argument(s)")
            recv match {
                Some(r) => {
                    sb.append(" on `")
                    format_with_names(
                        &self.engine.interner,
                        self.engine.resolve(r),
                        &sb,
                        Some(&self.nominals),
                    )
                    sb.append("`")
                }
                None => {}
            }
            push_diag_e(self, span, E_NO_OVERLOAD, sb.to_string())
            self.engine.fresh_var()
        }
    }
}

// A `move self` parameter takes the receiver's value, which a receiver reached through a reference
// or an `op_deref` hop does not have to give: the pointee stays with its owner (RFC-033). A
// receiver matched as written or auto-referenced is the ownership pass's business.
fn check_consuming_receiver(
    self: &Checker,
    p: &OverloadPick,
    name: String,
    recv: Ty?,
    span: SourceSpan,
) {
    if recv.is_none() or p.params.len == 0 or !pick_param_moves(self, p.id, 0usize) {
        return
    }
    const slot = self.engine.resolve(p.params[0])
    if ty_copyable(self, slot) {
        return
    }
    const through_ref = ty_node(self, self.engine.resolve(recv.unwrap())) match {
        NRef(_) => true
        _ => false
    }
    if !through_ref and p.hops == 0 {
        return
    }
    let sb = string_builder(128)
    sb.append(
        $"`{name}` takes ownership of its receiver, which is reached through a reference here - the value stays with its owner",
    )
    append_copy_blame(self, slot, &sb)
    own_report(self, span, E_CONSUMING_RECEIVER, sb.to_string())
}

// The `move` mask of function `id`'s declared parameters, as its function type carries it.
fn decl_moves(self: &Checker, id: u32) usize {
    const dp = self.fn_decl_params.get_ref(id)
    if dp.is_none() {
        return 0usize
    }
    let moves = 0usize
    const decl = &dp.unwrap().params
    for i in 0..decl.len {
        if decl[i].is_move and i < MAX_MOVE_PARAMS {
            moves = moves | move_bit(i)
        }
    }
    return moves
}

// Whether parameter `idx` of function `id` is declared `move`.
fn pick_param_moves(self: &Checker, id: u32, idx: usize) bool {
    const dp = self.fn_decl_params.get_ref(id)
    if dp.is_none() {
        return false
    }
    const decl = &dp.unwrap().params
    return idx < decl.len and decl[idx].is_move
}

// Park a call whose overload choice depends on a type that has not settled: copy what the redo
// needs and hand back a fresh var for the result. `resolve_pending_calls` finishes it after the
// specialization drain, when the open argument has its real type.
fn park_call(
    self: &Checker,
    call: &CallExpr,
    name: String,
    arg_tys: &List(Ty),
    pos_exprs: &List(&Expr),
    recv_extra: usize,
    alt_recv: Ty?,
) Ty {
    let args: List(Ty) = list(arg_tys.len)
    args.push_all(arg_tys.as_slice())
    let pes: List(&Expr) = list(pos_exprs.len)
    pes.push_all(pos_exprs.as_slice())
    self.pending_calls.push(PendingCall {
        span = call.span,
        name = name,
        call = call,
        arg_tys = move args,
        pos_exprs = move pes,
        recv_extra = recv_extra,
        alt_recv = alt_recv,
        module = self.current_module,
    })
    return self.engine.fresh_var()
}

// Redo every parked call now that inference has finished. A call whose argument settled resolves
// and commits exactly as it would have at the call site; one still undecided is the genuinely
// ambiguous case and reports (E2011) rather than picking by declaration order.
fn resolve_pending_calls(self: &Checker, from: usize = 0usize) {
    let parked: List(PendingCall) = list(self.pending_calls.len - from)
    while self.pending_calls.len > from {
        parked.push(self.pending_calls.pop().unwrap())
    }
    parked.reverse()
    const was_resolving = self.resolving_parked
    self.resolving_parked = true
    defer self.resolving_parked = was_resolving
    for pc in parked.drain() {
        let saved = self.current_module
        self.current_module = pc.module
        let vis = fn_visibility(self)
        defer vis.deinit()
        let cands = self.functions.lookup(pc.name, &vis) match {
            FnLookFound(c) => Some(move c)
            _ => null
        }
        if cands.is_some() {
            let candidates = cands.unwrap()
            self.overload_deferred = false
            let pchain: List(OverloadPick) = list(0)
            defer pchain.deinit()
            const pctx = PeelCtx { vis = &vis, chain = &pchain }
            const recv_span: SourceSpan? = if pc.recv_extra > 0 { Some(pc.span) } else { null }
            let pspans = arg_span_list(self, &pc.pos_exprs, recv_span)
            defer pspans.deinit()
            let pick = resolve_overload(
                self,
                &candidates,
                &pc.arg_tys,
                pc.span,
                pc.alt_recv,
                null,
                pc.recv_extra,
                true,
                Some(&pctx),
                Some(&pspans),
            )
            candidates.deinit()
            if pick.is_none() and self.overload_deferred {
                self.overload_deferred = false
                push_diag_e(
                    self,
                    pc.span,
                    E_NO_OVERLOAD,
                    $"ambiguous call to `{pc.name}`: several overloads match and the argument type never settled - annotate it",
                )
            } else {
                const n_args = if pc.recv_extra > 0 { pc.arg_tys.len - 1 } else { pc.arg_tys.len }
                const pc_recv: Ty? = if pc.recv_extra > 0 { Some(pc.arg_tys[0]) } else { null }
                let t = commit_pick(
                    self,
                    pick,
                    pc.name,
                    n_args,
                    pc.span,
                    pc.recv_extra,
                    &pc.pos_exprs,
                    null,
                    pc_recv,
                )
                // The placeholder `park_call` handed the call site flowed into the enclosing
                // inference; the resolved type has to reach those uses, not just the node.
                const node = self.node_of(pc.span)
                const held = self.results.node_types.get(node)
                if held.is_some() {
                    const o = self.engine.unify(held.unwrap(), t)
                    report_unify(self, &o, E_TYPE_MISMATCH, pc.span)
                }
                self.results.record_type(node, t)
            }
        }
        self.current_module = saved
        pc.arg_tys.deinit()
        pc.pos_exprs.deinit()
    }
    parked.deinit()
}

// W2002: calling a `#deprecated` function. The table is keyed by function id and holds ONLY the
// deprecated ones, so the common path is
// a single miss - scanning the registry per call site was O(functions ×
// call sites) and showed up as minutes of compile time.
fn warn_deprecated_call(self: &Checker, id: u32, name: String, span: SourceSpan) {
    let dep = self.fn_deprecations.get(id)
    if dep.is_none() {
        return
    }
    let msg = dep.unwrap()
    if msg.len == 0 {
        push_diag_w(self, span, W_DEPRECATED_FN, $"function `{name}` is deprecated")
    } else {
        push_diag_w(self, span, W_DEPRECATED_FN, $"function `{name}` is deprecated: {msg}")
    }
}

// A named-argument call reaches lowering as a FULL argument list in parameter order (the
// reference's `BuildResolvedArguments`): a name selects its parameter, the positional arguments
// fill the remaining slots left to right, and anything still empty takes the declaration's default.
// It shares the `default_args` table with the omitted-tail records - a call whose `args` contain a
// `Named` slot reads its entry as the COMPLETE list and ignores `call.args` entirely, every other
// call reads it as the tail to append. The receiver of a UFCS call is not in the list; lowering
// prepends it either way.
//
// Bail-outs leave no record, so lowering refuses the enclosing function rather than emit a call C
// would mis-order: a slot with no argument and no default, a leftover positional or named argument
// (arity/name errors the reference reports as E2067/E2068/E2069 - not yet diagnosed here), or a
// defaulted parameter whose instantiated type still carries a free var (see
// `materialize_default_args`).
// Whether the winner's last parameter is the variadic tail.
fn pick_is_variadic(self: &Checker, p: &OverloadPick) bool {
    let dp = self.fn_decl_params.get_ref(p.id)
    if dp.is_none() {
        return false
    }
    let decl = &dp.unwrap().params
    if decl.len == 0 {
        return false
    }
    return decl[decl.len - 1].is_variadic
}

fn materialize_arg_list(
    self: &Checker,
    p: &OverloadPick,
    pos_exprs: &List(&Expr),
    named: &NamedArgs?,
    recv_extra: usize,
    span: SourceSpan,
) {
    if self.default_depth >= MAX_DEFAULT_DEPTH {
        return
    }
    let dp = self.fn_decl_params.get_ref(p.id)
    if dp.is_none() {
        return
    }
    let decl_params = &dp.unwrap().params
    if decl_params.len != p.params.len {
        return
    }
    if recv_extra > decl_params.len {
        return
    }

    self.default_depth = self.default_depth + 1
    let exprs: List(&Expr) = list(decl_params.len - recv_extra)
    let n_named = named match { Some(n) => n.names.len, None => 0usize }
    let used_named = 0usize
    let next_pos = 0usize
    let ok = true
    for pi in recv_extra..decl_params.len {
        if !ok {
            continue
        }
        // The variadic tail swallows every remaining positional argument as one synthesized array
        // literal - the reference's `BuildResolvedArguments` builds the same node, and the array
        // decays to the parameter's slice at the call.
        if decl_params[pi].is_variadic {
            exprs.push(synth_box(
                self,
                synth_variadic_pack(self, pos_exprs, next_pos, p.params[pi], span),
            ))
            next_pos = pos_exprs.len
            continue
        }
        let from_named: usize? = null
        named match {
            Some(na) => {
                for j in 0..na.names.len {
                    if from_named.is_none() and na.names[j] == decl_params[pi].name {
                        from_named = Some(j)
                    }
                }
                if from_named.is_some() {
                    exprs.push(na.values[from_named.unwrap()])
                }
            }
            None => {}
        }
        if from_named.is_some() {
            used_named = used_named + 1
            continue
        }
        if next_pos < pos_exprs.len {
            exprs.push(pos_exprs[next_pos])
            next_pos = next_pos + 1
            continue
        }
        if ty_has_free_var(self, self.engine.resolve(p.params[pi])) {
            ok = false
            continue
        }
        decl_params[pi].default_value match {
            Some(e) => {
                const t = check_default(self, p.id, e)
                unify_expected(self, t, p.params[pi], E_TYPE_MISMATCH, span)
                exprs.push(e)
            }
            None => ok = false
        }
    }
    self.default_depth = self.default_depth - 1

    if ok and next_pos == pos_exprs.len and used_named == n_named {
        self.results.record_arg_list(self.node_of(span), exprs)
    } else {
        exprs.deinit()
    }
}

// `[a, b, c]` over the positional arguments from `from` on, checked in place so its node types land
// in this result set, and unified against the variadic parameter's slice element type so unsuffixed
// literals pin. Synthetic span - node ids are span fingerprints, and this node exists nowhere in
// the source.
fn synth_variadic_pack(
    self: &Checker,
    pos_exprs: &List(&Expr),
    from: usize,
    param_ty: Ty,
    span: SourceSpan,
) Expr {
    // The pack shares the argument nodes the module arena owns.
    let elems: List(Expr) = list(pos_exprs.len - from)
    for e in pos_exprs.as_slice()[from..pos_exprs.len] {
        elems.push(e.*)
    }
    const arr = Expr.ArrayLit(ArrayLiteralExpr {
        span = synth_span(self),
        kind = ArrayLiteralKind.Elements(frozen(elems)),
    })
    const at = check_expr(self, &arr)
    // The parameter is `Slice(T)`; unify the literal's element type with `T` so the arguments
    // settle (an empty pack leaves `T` to the declaration, which already fixed it).
    let want = self.engine.resolve(param_ty)
    let elem = ty_node(self, want) match {
        NNominal(nn) => if nn.args.len == 1 { Some(self.engine.interner.child_at(
            nn.args,
            0,
        )) } else { null }
        _ => null
    }
    if elem.is_some() {
        let az = self.engine.resolve(at)
        ty_node(self, az) match {
            NArray(a) => {
                const o = self.engine.unify(a.elem, elem.unwrap())
                report_unify(self, &o, E_TYPE_MISMATCH, span)
            }
            _ => {}
        }
    }
    return arr
}

// M11: a call that supplied fewer arguments than the winner's arity left the rest to defaults. The
// reference clones each omitted default expression and infers it at the call site; node ids here
// are span fingerprints, so a clone would collide with its source - instead the declaration's own
// default exprs are checked in place (shallow copies sharing the AST's children), unified against
// the winner's instantiated parameter types, and the list is recorded on the call node for lowering
// to append after the explicit arguments.
//
// Identifiers inside a default resolve as at the declaration (`check_default`).
//
// Bail-outs (call lowers short and refuses, exactly the pre-M11 state): an omitted param with no
// default (the variadic tail), a defaulted param whose instantiated type still carries a free var
// (the shared decl nodes must pin ONE type - a `$T`-typed default would record a different type per
// call site), and materialization deeper than MAX_DEFAULT_DEPTH (a default whose own call omits
// defaults recurses; a self-referential default would never terminate).
const MAX_DEFAULT_DEPTH: usize = 16

fn materialize_default_args(self: &Checker, p: &OverloadPick, supplied: usize, span: SourceSpan) {
    if supplied >= p.params.len {
        return
    }
    if self.default_depth >= MAX_DEFAULT_DEPTH {
        return
    }
    let dp = self.fn_decl_params.get_ref(p.id)
    if dp.is_none() {
        return
    }
    let decl_params = &dp.unwrap().params
    if decl_params.len != p.params.len {
        return
    }

    self.default_depth = self.default_depth + 1
    let exprs: List(&Expr) = list(p.params.len - supplied)
    let ok = true
    for i in supplied..decl_params.len {
        if !ok {
            continue
        }
        if ty_has_free_var(self, self.engine.resolve(p.params[i])) {
            ok = false
            continue
        }
        decl_params[i].default_value match {
            Some(e) => {
                const t = check_default(self, p.id, e)
                unify_expected(self, t, p.params[i], E_TYPE_MISMATCH, span)
                exprs.push(e)
            }
            None => ok = false
        }
    }
    self.default_depth = self.default_depth - 1

    if ok {
        self.results.record_default_args(self.node_of(span), exprs)
    } else {
        exprs.deinit()
    }
}

// A parameter's default checked at a call as its declaration sees it: in the declaring module, with
// the caller's locals hidden.
fn check_default(self: &Checker, fn_id: u32, e: &Expr) Ty {
    const caller_module = self.current_module
    const decl = self.functions.find_by_id(fn_id)
    if decl.is_some() and decl.unwrap().module.is_some() {
        self.current_module = decl.unwrap().module
    }
    const hidden = self.env.hide_locals()
    const t = check_expr(self, e)
    self.env.reveal(hidden)
    self.current_module = caller_module
    return t
}

// E2111 (RFC-014): when an overload failed and one of the arguments is a capturing closure, the
// likely cause is a bare `fn` parameter the closure cannot decay into - say so instead of the
// generic message.
fn closure_arg_hint(self: &Checker, arg_tys: &List(Ty), span: SourceSpan) bool {
    for i in 0..arg_tys.len {
        let z = self.engine.resolve(arg_tys[i])
        let cls = closure_of(self, z)
        if cls.is_some() {
            push_diag_e(
                self,
                span,
                E_CLOSURE_TO_FN,
                from_view(
                    "a capturing closure cannot coerce to a bare `fn` parameter (it has no environment slot); pass it through a generic `$F` parameter instead",
                ),
            )
            return true
        }
    }
    return false
}

// `recv.field(args)` where `field` is a Func-typed struct field - the vtable-dispatch pattern. Null
// when the receiver is not a struct or has no Func field by that name - the UFCS path takes over.
fn field_call(
    self: &Checker,
    recv_ty: Ty,
    name: String,
    arg_tys: &List(Ty),
    span: SourceSpan,
    callee_id: NodeId,
) Ty? {
    let fty = struct_field_lookup(self, recv_ty, name)
    if is_context_ty(self, recv_ty) {
        fty = context_field_silent(self, name, span)
    }
    if fty.is_none() {
        return null
    }
    let zf = self.engine.resolve(fty.unwrap())
    // The callee member-access node's type is what lowering classifies the dispatch by (closure ->
    // direct op_call, fn value -> indirect); record it - the manual resolution here bypasses
    // `check_expr`.
    self.results.record_type(callee_id, zf)
    // A field holding a capturing closure dispatches like any closure value - `self.f(x)` inside an
    // adapter struct.
    let cls = closure_of(self, zf)
    if cls.is_some() {
        return Some(indirect_call(self, zf, arg_tys, span))
    }
    let f = ty_node(self, zf) match {
        NFunc(ft) => ft
        _ => return null
    }
    if f.params.len != arg_tys.len {
        push_diag_e(
            self,
            span,
            E_NO_OVERLOAD,
            $"no matching overload for `{name}` with {arg_tys.len} argument(s)",
        )
        return Some(self.engine.fresh_var())
    }
    for i in 0..arg_tys.len {
        const o = self.engine.unify(arg_tys[i], self.engine.interner.child_at(f.params, i))
        report_unify(self, &o, E_TYPE_MISMATCH, span)
    }
    return Some(f.ret)
}

// The type of the context field `name` as a call's callee, or null - quietly, so the call falls
// back to UFCS - when no single visible field has the name.
fn context_field_silent(self: &Checker, name: String, span: SourceSpan) Ty? {
    const before = self.diagnostics.len
    const hit = resolve_context_field(self, name, span)
    drop_diags_from(self, before)
    return hit match {
        Some(h) => {
            record_context_target(self, span, h.fqn)
            Some(h.field.ty)
        }
        None => null
    }
}

// The closure-call signature for a value of synthesized-closure type, or null when the type is not
// a closure nominal.
fn closure_of(self: &Checker, ty: Ty) &ClosureSig? {
    let nid = ty_node(self, ty) match {
        NNominal(nn) => Some(nn.id)
        _ => null
    }
    if nid.is_none() {
        return null
    }
    return self.closures.get_ref(nid.unwrap())
}

// A callee that is a value: a Func-typed binding calls directly; an unresolved binding is
// constrained to a function of the call's shape (so lambda-typed locals infer); anything else is
// not callable.
fn indirect_call(self: &Checker, callee_ty: Ty, arg_tys: &List(Ty), span: SourceSpan) Ty {
    let z = self.engine.resolve(callee_ty)
    // A capturing closure (RFC-014) dispatches through its synthesized op_call - the value's
    // nominal id keys the global closure table, so this works in any body a closure reached through
    // a `$F` slot.
    let cls = closure_of(self, z)
    if cls.is_some() {
        let c = cls.unwrap()
        if c.params.len != arg_tys.len {
            push_diag_e(
                self,
                span,
                E_NO_OVERLOAD,
                $"no matching overload with {arg_tys.len} argument(s)",
            )
            return self.engine.fresh_var()
        }
        for i in 0..arg_tys.len {
            const o = self.engine.unify(arg_tys[i], c.params[i])
            report_unify(self, &o, E_TYPE_MISMATCH, span)
        }
        return c.ret
    }
    let ft = ty_node(self, z) match {
        NFunc(f) => Some(f)
        _ => null
    }
    if ft.is_some() {
        let f = ft.unwrap()
        if f.params.len != arg_tys.len {
            push_diag_e(
                self,
                span,
                E_NO_OVERLOAD,
                $"no matching overload with {arg_tys.len} argument(s)",
            )
            return self.engine.fresh_var()
        }
        for i in 0..arg_tys.len {
            const o = self.engine.unify(arg_tys[i], self.engine.interner.child_at(f.params, i))
            report_unify(self, &o, E_TYPE_MISMATCH, span)
        }
        return f.ret
    }
    // RFC-014 Phase 1: any value whose type declares `op_call` is callable. Resolved like a UFCS
    // method call with the value as the receiver, so lowering reuses the receiver prepend +
    // adaptation.
    let oc = op_call_dispatch(self, z, arg_tys, span)
    if oc.is_some() {
        return oc.unwrap()
    }

    if z.is_error() {
        return TY_ERROR
    }
    if self.engine.is_rigid(z) and !rigid_callable(self, z) {
        push_diag_e(
            self,
            span,
            E_UNBOUNDED_CALL,
            from_view(
                "this value's type is a type parameter with no callable bound - bound it by its shape: `where F: fn(...) R`",
            ),
        )
        return TY_ERROR
    }
    if self.engine.is_var(z) {
        let ps = list(arg_tys.len)
        ps.push_all(arg_tys.as_slice())
        let ret = self.engine.fresh_var()
        const o = self.engine.unify(callee_ty, self.engine.mk_func(ps, ret))
        report_unify(self, &o, E_TYPE_MISMATCH, span)
        return ret
    }
    // Reference parity: a non-callable callee is "Unresolved function" (E2004), not an overload
    // failure - the name simply named nothing callable.
    push_diag_e(
        self,
        span,
        E_UNKNOWN_IDENT,
        from_view("unresolved function: expression of non-function type is not callable"),
    )
    return self.engine.fresh_var()
}

// `c(args)` where `c` is a VALUE of nominal type: resolve against the `op_call` overloads with `c`
// as the receiver, peeling `op_deref` hops when the type wraps another that declares `op_call`
// (`Wrapper(Counter)` → `Counter.op_call`). The pick is committed on the
// call node exactly like a UFCS method call, and the receiver chain (empty when no peeling was
// needed) is recorded there too - its presence is what tells lowering the CALLEE is the receiver.
fn op_call_dispatch(self: &Checker, recv: Ty, arg_tys: &List(Ty), span: SourceSpan) Ty? {
    let is_nominal = ty_node(self, recv) match { NNominal(_) => true, _ => false }
    if !is_nominal {
        return null
    }
    let vis = fn_visibility(self)
    defer vis.deinit()
    let cands = self.functions.lookup("op_call", &vis) match {
        FnLookFound(c) => Some(move c)
        _ => null
    }
    if cands.is_none() {
        return null
    }
    let candidates = cands.unwrap()
    defer candidates.deinit()

    // `op_call(&T, …)`, `op_call(T, …)` and the receiver's `op_deref` targets compete in one
    // ranked set.
    let chain: List(OverloadPick) = list(0)
    defer chain.deinit()
    let ctx = PeelCtx { vis = &vis, chain = &chain }
    let pick = receiver_overload(
        self,
        &candidates,
        recv,
        arg_tys,
        span,
        Some(self.engine.mk_ref(recv)),
        null,
        Some(&ctx),
    )
    if pick.is_none() {
        return null
    }
    const hops = pick_hops(&pick)
    commit_deref_chain(self, &chain, hops, span)
    if hops == 0 {
        // The chain record, even empty, is lowering's signal that this plain-looking callee is an
        // `op_call` dispatch (the AST shows no receiver).
        let none: List(ResolvedTarget) = list(0)
        self.results.record_receiver_deref(self.node_of(span), none)
    }
    let no_exprs: List(&Expr) = list(0)
    defer no_exprs.deinit()
    return Some(commit_pick(self, pick, "op_call", arg_tys.len, span, 1usize, &no_exprs, null))
}

// Appends to `alts` every receiver shape reachable from `recv` through `op_deref`, at most ten hops
// deep: per hop, the wrapped value by reference and then by value. Each hop's pick goes on
// `ctx.chain`, outermost first. Stops at a receiver that is not a nominal or has no `op_deref`.
// Hops are resolved non-speculatively, so a chain the winner does not use leaves its deref
// unifications behind.
fn deref_alternatives(
    self: &Checker,
    recv: Ty,
    span: SourceSpan,
    ctx: &PeelCtx,
    alts: &List(RecvAlt),
) {
    let dcands = deref_candidates(self, ctx.vis)
    if dcands.is_none() {
        return
    }
    let dc = dcands.unwrap()
    defer dc.deinit()
    let current = self.engine.resolve(recv)
    let hops = 0usize
    while hops < 10 {
        let peeled = ty_node(self, current) match {
            NRef(inner) => self.engine.resolve(inner)
            _ => current
        }
        let is_nominal = ty_node(self, peeled) match { NNominal(_) => true, _ => false }
        if !is_nominal {
            return
        }

        let dargs = list(1)
        dargs.push(self.engine.mk_ref(peeled))
        let dpick = resolve_overload(self, &dc, &dargs, span)
        dargs.deinit()
        if dpick.is_none() {
            return
        }
        const hop = dpick.unwrap()
        const hop_ret = hop.ret
        ctx.chain.push(hop)
        hops = hops + 1

        let dret = self.engine.resolve(hop_ret)
        let inner = ty_node(self, dret) match {
            NRef(i) => self.engine.resolve(i)
            _ => return
        }
        alts.push(RecvAlt { ty = dret, penalty = (2 * hops) as u32, hops = hops })
        alts.push(RecvAlt { ty = inner, penalty = (2 * hops + 1) as u32, hops = hops })
        current = inner
    }
}

// The winning overload for a call site: registry id plus instantiated return type. For a generic
// winner, `inst` carries the instantiation the commit sites turn into a `PendingSpec` (M10); null
// for monomorphic winners.
type OverloadPick = struct {
    id: u32
    ret: Ty
    // The winner's instantiated parameter types (engine-owned storage), for unifying materialized
    // default arguments (M11).
    params: List(Ty)
    inst: PickInst?
    // How many `op_deref` hops the receiver went through to match: the prefix of the caller's peel
    // chain to record for lowering. Zero for a receiver matched as written or adapted.
    hops: usize
    // The receiver matched adapted between value and reference; null as written or through hops.
    adapt: ReceiverAdapt?
}

pub fn deinit(self: move OverloadPick) {
    self.params.deinit()
    self.inst.deinit()
}

// One shape a receiver may take in overload resolution besides as written: adapted between value
// and reference, or the wrapped value reached through `op_deref` hops. `penalty` orders the shapes
// at equal specificity (adapted, then each hop by reference before by value); `hops` is how many
// entries of the peel chain lead to it.
type RecvAlt = struct {
    ty: Ty
    penalty: u32
    hops: usize
}

// `resolve_overload`'s bookkeeping for one candidate: its probe against the receiver shapes tried
// so far (null while it matches none), which shape it matched (`RecvAlt` index + 1, 0 for as
// written), and its structural specificity.
type CandProbe = struct {
    cost: ProbeCost?
    used: usize
    spec: u32
}

// What `resolve_overload` needs to try a receiver through `op_deref`: the visibility to look the
// `op_deref` overloads up in (only once a peel is actually attempted - most calls never get there),
// and the chain each hop's pick is appended to. The caller records the winner's `hops` prefix of it
// (`commit_deref_chain`).
type PeelCtx = struct {
    vis: &Visibility
    chain: &List(OverloadPick)
}

// A generic winner's instantiated shape: the quantified-id → fresh-var
// mapping plus the fresh-var-bearing parameter and return types. All zonk to concrete types once
// the surrounding inference settles.
type PickInst = struct {
    tp_binds: Dict(VarId, Ty)
    params: List(Ty)
    ret: Ty
}

pub fn deinit(self: move PickInst) {
    self.tp_binds.deinit()
    self.params.deinit()
}

// Pick the best candidate for the argument types and commit its unification. Each candidate is
// probed inside an engine checkpoint that is rolled back, so losing candidates leave no bindings.
// Arity accepts [required, total]: trailing defaulted params may be omitted and a variadic tail
// takes any surplus. Preference: fewer implicit conversions first - an argument matching its
// parameter type as-is always beats one that had to be coerced (a String literal IS a String and
// decays to u8[] only when no String parameter takes it) - then higher structural specificity (each
// concrete type constructor is a constraint the arguments satisfied - `Dict($K,$V)` beats the
// catch-all `$T`), then lower total cost (receiver adaptation, omitted defaults), then fewer
// quantified vars, then the candidate whose return type fits `expected` (the typed slot the call
// fills), then registration order.
fn resolve_overload(
    self: &Checker,
    candidates: &List(&FunctionScheme),
    arg_tys: &List(Ty),
    span: SourceSpan,
    alt_recv: Ty? = null,
    named: &NamedArgs? = null,
    ufcs_offset: usize = 0usize,
    report_ambiguity: bool = false,
    peel: &PeelCtx? = null,
    arg_spans: &List(SourceSpan)? = null,
    expected: Ty? = null,
) OverloadPick? {
    // The receiver shapes, tried in tiers across all candidates (spec 7.2): as written (`arg_tys`
    // itself); when no candidate accepts that, `alt_recv` - the UFCS receiver adapted value <-> &T;
    // when none accepts that either, the wrapped values reached through `op_deref`. Only the first
    // tier anything matched in is ranked: a candidate that takes the receiver as written wins over
    // one that needs `&x` or a hop, however specific. `st[ci].used` is 0 for as written, else 1 +
    // the index into `alts`. Both lists allocate only once a shape is pushed: a plain direct call
    // never pays for them.
    let alts: List(RecvAlt) = list(0)
    defer alts.deinit()
    let alt_args: List(List(Ty)) = list(0)
    defer alt_args.deinit()
    if alt_recv.is_some() and arg_tys.len > 0 {
        alts.push(RecvAlt { ty = alt_recv.unwrap(), penalty = 1u32, hops = 0usize })
        alt_args.push(args_with_recv(self, arg_tys, alt_recv.unwrap()))
    }

    let st: List(CandProbe) = list(candidates.len)
    defer st.deinit()
    // The first candidate the arguments fit, in some receiver shape, but whose bounds refused them:
    // picked when nothing else fits, so the drain names the requirement that failed (E2134) rather
    // than the call reporting no overload at all. `.1` is the shape, as `CandProbe.used` counts it.
    let bound_refused: (usize, usize)? = null
    for c in candidates {
        const probed = probe_candidate(self, c, arg_tys, named, ufcs_offset, peel, span)
        if self.probe_bound_failed and bound_refused.is_none() {
            bound_refused = Some((st.len, 0usize))
        }
        const spec = if probed.is_some() { scheme_specificity(
            self,
            &c.signature,
            arg_tys,
        ) } else { 0u32 }
        st.push(CandProbe { cost = probed, used = 0usize, spec = spec })
    }
    if alts.len > 0 and peel_needed(&st) {
        for ci in 0..candidates.len {
            const ap = probe_candidate(
                self,
                candidates[ci],
                &alt_args[0],
                named,
                ufcs_offset,
                peel,
                span,
            )
            if self.probe_bound_failed and bound_refused.is_none() {
                bound_refused = Some((ci, 1usize))
            }
            if ap.is_some() {
                st[ci].cost = Some(ProbeCost {
                    coercions = ap.unwrap().coercions,
                    penalty = ap.unwrap().penalty + alts[0].penalty,
                    held = ap.unwrap().held,
                })
                st[ci].used = 1usize
                st[ci].spec = scheme_specificity(self, &candidates[ci].signature, arg_tys)
            }
        }
    }

    // The peel, only when nothing took the receiver as written or adapted.
    if peel.is_some() and ufcs_offset > 0 and arg_tys.len > 0 and peel_needed(&st) {
        let first = alts.len
        deref_alternatives(self, arg_tys[0], span, peel.unwrap(), &alts)
        for ai in first..alts.len {
            alt_args.push(args_with_recv(self, arg_tys, alts[ai].ty))
        }
        for ci in 0..candidates.len {
            if st[ci].cost.is_some() {
                continue
            }
            for ai in first..alts.len {
                let ap = probe_candidate(
                    self,
                    candidates[ci],
                    &alt_args[ai],
                    named,
                    ufcs_offset,
                    peel,
                    span,
                )
                if self.probe_bound_failed and bound_refused.is_none() {
                    bound_refused = Some((ci, ai + 1))
                }
                if ap.is_some() {
                    st[ci].cost = Some(ProbeCost {
                        coercions = ap.unwrap().coercions,
                        penalty = ap.unwrap().penalty + alts[ai].penalty,
                        held = ap.unwrap().held,
                    })
                    st[ci].used = ai + 1
                    st[ci].spec = scheme_specificity(self, &candidates[ci].signature, arg_tys)
                    break
                }
            }
        }
    }

    // Inside a satisfaction check a refusal stands: the requirement does not resolve.
    if bound_refused.is_some() and peel_needed(&st) and self.bound_depth == 0 {
        const refused = bound_refused.unwrap()
        st[refused.0].cost = Some(ProbeCost { coercions = 0u32, penalty = 0u32, held = 0u32 })
        st[refused.0].used = refused.1
    }

    let best: usize? = null
    let best_coercions = 0u32
    let best_cost = 0u32
    let best_generics = 0usize
    let best_spec = 0u32
    let best_bounded = 0u32
    let ambiguous = false
    let var_ambiguous = false

    for ci in 0..candidates.len {
        let c = candidates[ci]
        let probed = st[ci].cost
        if probed.is_some() {
            const p = probed.unwrap()
            let coercions = p.coercions
            let cost = p.total()
            let generics = c.signature.quantified.len()
            let spec = st[ci].spec
            // A stricter bound is more specific (RFC-035), below any concrete type constructor.
            let bounded = p.held
            const same_shape = coercions == best_coercions and spec == best_spec
            let better = best.is_none() or coercions < best_coercions
                or (coercions == best_coercions and spec > best_spec) or (same_shape
                    and bounded > best_bounded) or (same_shape and bounded == best_bounded
                        and cost < best_cost) or (same_shape and bounded == best_bounded
                            and cost == best_cost and generics < best_generics)
            if better {
                best = Some(ci)
                best_coercions = coercions
                best_cost = cost
                best_generics = generics
                best_spec = spec
                best_bounded = bounded
                ambiguous = false
            } else if best.is_some() {
                // An exact tie on every ranking key. Who breaks it decides what happens: an
                // unsuffixed LITERAL has no preferred type in FLang, so declaration order would be
                // picking for the user - say so (E2011). An argument that is still an open type
                // VARIABLE is a different story: something later in the program may yet settle it
                // (a generic whose return type its own body derives), so the call is parked and
                // re-resolved once inference has finished.
                let tied = same_shape and bounded == best_bounded and cost == best_cost
                    and generics == best_generics
                if tied {
                    tie_breaker(self, candidates, best.unwrap(), ci, arg_tys) match {
                        TieByLiteral => ambiguous = true
                        TieByOpenVar => var_ambiguous = true
                        TieByShape => {
                            // Overloads that differ only in their return type: the slot the call
                            // fills chooses, where it has a type.
                            const takes_ci = expected.is_some() and returns_into(
                                self,
                                c,
                                expected.unwrap(),
                            ) and !returns_into(self, candidates[best.unwrap()], expected.unwrap())
                            if takes_ci {
                                best = Some(ci)
                            }
                        }
                    }
                }
            }
        }
    }
    if best.is_none() {
        return null
    }
    if ambiguous {
        if report_ambiguity {
            push_diag_e(
                self,
                span,
                E_NO_OVERLOAD,
                from_view(
                    "ambiguous call: several overloads match equally well and an argument is an unsuffixed literal with no preferred type, so the choice would be arbitrary - add a literal suffix or annotate the value",
                ),
            )
        }
        return null
    }
    // Nothing here can choose yet - committing would bind the open argument to whichever overload
    // happens to be declared first. The caller parks the call (`overload_deferred`).
    if var_ambiguous and report_ambiguity {
        self.overload_deferred = true
        return null
    }

    let w = candidates[best.unwrap()]
    let binds: Dict(VarId, Ty) = dict()
    let inst_ty = self.engine.resolve(self.engine.specialize_capture(&w.signature, &binds))
    let ft = ty_node(self, inst_ty) match {
        NFunc(x) => Some(x)
        _ => null
    }
    if ft.is_none() {
        binds.deinit()
        return null
    }
    let f = ft.unwrap()
    // A scratch copy of the instantiated parameter window: it rides on the pick for
    // default-argument unification and the pending spec.
    let fparams: List(Ty) = list(f.params.len)
    for i in 0..f.params.len {
        fparams.push(self.engine.interner.child_at(f.params, i))
    }
    let checked = non_variadic_arg_count(w, fparams.len, arg_tys.len)
    let best_used = st[best.unwrap()].used
    for i in 0..checked {
        // Commit with the receiver shape the winner actually matched.
        let arg = if i == 0 and best_used > 0 { alts[best_used - 1].ty } else { arg_tys[i] }
        const o = self.engine.unify(arg, fparams[i])
        const fitted = o match { Unified(_) => true, _ => false }
        if fitted
            or !commit_arg_peel(self, arg, fparams[i], i, ufcs_offset, span, arg_spans, peel) {
            report_unify(self, &o, E_TYPE_MISMATCH, span)
        }
    }
    // The variadic tail's surplus arguments commit against its element type - without this an
    // unsuffixed literal in the tail never pins.
    if w.has_variadic and fparams.len > 0 {
        let ve = variadic_elem(self, fparams[fparams.len - 1])
        if ve.is_some() {
            for k in checked..arg_tys.len {
                const ov = self.engine.unify(arg_tys[k], ve.unwrap())
                report_unify(self, &ov, E_TYPE_MISMATCH, span)
            }
        }
    }
    // Named arguments commit against the parameter their name selected.
    if named.is_some() {
        let na = named.unwrap()
        let slots = named_param_slots(self, w, na, ufcs_offset)
        if slots.is_some() {
            let sl = slots.unwrap()
            for i in 0..sl.len {
                if sl[i] < fparams.len {
                    const on = self.engine.unify(na.tys[i], fparams[sl[i]])
                    report_unify(self, &on, E_TYPE_MISMATCH, span)
                }
            }
            sl.deinit()
        }
    }
    // What the winner's bounds solve - `$T` from `Iterator($T)`, a lambda's parameter types from
    // `fn(T) bool` - is kept; a bound that fails is the drain's to report.
    const _check = check_bounds(self, w.id, Some(&binds), true, false)
    // The pick and its instantiation each carry their own copy of the parameter window.
    let inst: PickInst? = null
    if w.signature.quantified.len() > 0 {
        let inst_params: List(Ty) = list(fparams.len)
        inst_params.push_all(fparams.as_slice())
        install(
            &inst,
            Some(PickInst { tp_binds = move binds, params = move inst_params, ret = f.ret }),
        )
    } else {
        binds.deinit()
    }
    let hops = if best_used > 0 { alts[best_used - 1].hops } else { 0usize }
    let adapt: ReceiverAdapt? = null
    if best_used > 0 and hops == 0 {
        adapt = ty_node(self, alts[best_used - 1].ty) match {
            NRef(_) => Some(ReceiverAdapt.ByRef)
            _ => Some(ReceiverAdapt.ByValue)
        }
    }
    return Some(OverloadPick {
        id = w.id,
        ret = f.ret,
        params = move fparams,
        inst = move inst,
        hops = hops,
        adapt = adapt,
    })
}

// Commits a winning argument's `op_deref` hops: unifies through the chain and records it on the
// argument's own node, the way a receiver's chain is recorded on the call node. Lowering replays it
// before the call. False when the argument does not reach the parameter that way, leaving the
// caller to report the mismatch it already has.
fn commit_arg_peel(
    self: &Checker,
    arg: Ty,
    param: Ty,
    index: usize,
    ufcs_offset: usize,
    span: SourceSpan,
    arg_spans: &List(SourceSpan)?,
    peel: &PeelCtx?,
) bool {
    if peel.is_none() or arg_spans.is_none() or index < ufcs_offset {
        return false
    }
    const spans = arg_spans.unwrap()
    if index >= spans.len {
        return false
    }
    let chain: List(OverloadPick) = list(2)
    defer chain.deinit()
    const ctx = PeelCtx { vis = peel.unwrap().vis, chain = &chain }
    const hops = peel_arg(self, arg, param, span, &ctx, Some(&chain))
    if hops.is_none() {
        return false
    }
    commit_deref_chain(self, &chain, hops.unwrap(), spans[index], true)
    return true
}

// The hop count of a pick that matched, read without taking the pick.
fn pick_hops(pick: &Option(OverloadPick)) usize {
    return pick.* match {
        Some(p) => p.hops
        None => 0usize
    }
}

// Whether the next receiver tier is tried: no candidate matched in the tiers so far. Adaptation and
// the `op_deref` peel are fallbacks - UFCS does not change which overload wins, so a catch-all that
// takes the receiver as written takes the call.
fn peel_needed(st: &List(CandProbe)) bool {
    for &c in st {
        if c.cost.is_some() {
            return false
        }
    }
    return true
}

// Whether `supplied` arguments fall in the candidate's arity window: at least the required ones,
// and no more than declared unless a variadic tail takes the surplus.
fn arity_accepts(c: &FunctionScheme, n_params: usize, supplied: usize) bool {
    return supplied >= c.required_params and (c.has_variadic or supplied <= n_params)
}

// The spans of a call's arguments, aligned with its argument types, so a winning argument's
// `op_deref` chain is recorded on the argument's own node. `recv` is the receiver's span for a UFCS
// call, which occupies the first slot.
fn arg_span_list(self: &Checker, pos_exprs: &List(&Expr), recv: SourceSpan?) List(SourceSpan) {
    let out: List(SourceSpan) = list(pos_exprs.len + 1)
    if recv.is_some() {
        out.push(recv.unwrap())
    }
    for &e in pos_exprs {
        out.push(expr_span(e.*))
    }
    return out
}

// `arg_tys` with its first entry - the receiver - replaced by `recv`.
fn args_with_recv(self: &Checker, arg_tys: &List(Ty), recv: Ty) List(Ty) {
    let out: List(Ty) = list(arg_tys.len)
    out.push(recv)
    for i in 1..arg_tys.len {
        out.push(arg_tys[i])
    }
    return out
}

// Whether the tie between two equally-ranked candidates turns on an argument that is a still-open
// literal: the two declare DIFFERENT concrete types at a position the literal could take either
// way. What breaks a dead-even overload tie, if anything: an argument that is an unsuffixed LITERAL
// (no preferred type, nothing later will settle it - E2011), one that is a still-OPEN type (park
// the call and redo it once it settles), or nothing at all (declaration order is fine).
type TieBreaker = enum {
    TieByLiteral
    TieByOpenVar
    TieByShape
}

// Whether `c`'s return type, freshly instantiated, unifies with `expected`. Probed and rolled back.
fn returns_into(self: &Checker, c: &FunctionScheme, expected: Ty) bool {
    const fn_ty = self.engine.resolve(self.engine.specialize(&c.signature))
    const ret = ty_node(self, fn_ty) match {
        NFunc(f) => f.ret
        _ => return false
    }
    return self.engine.try_unify(ret, expected) match {
        Unified(_) => true
        _ => false
    }
}

fn tie_breaker(
    self: &Checker,
    candidates: &List(&FunctionScheme),
    a: usize,
    b: usize,
    arg_tys: &List(Ty),
) TieBreaker {
    let fa = scheme_fn_ty(self, &candidates[a].signature)
    let fb = scheme_fn_ty(self, &candidates[b].signature)
    if fa.is_none() or fb.is_none() {
        return TieBreaker.TieByShape
    }
    let pa = fa.unwrap().params
    let pb = fb.unwrap().params
    let out = TieBreaker.TieByShape
    for i in 0..arg_tys.len {
        if i >= pa.len or i >= pb.len {
            continue
        }
        if !self.engine.is_var(self.engine.resolve(arg_tys[i])) {
            continue
        }
        let ta = self.engine.resolve(self.engine.interner.child_at(pa, i))
        let tb = self.engine.resolve(self.engine.interner.child_at(pb, i))
        if self.engine.is_var(ta) or self.engine.is_var(tb) {
            continue
        }
        if ta == tb {
            continue
        }
        // A literal wins the report: it is the one nothing can settle.
        if is_literal_var(self, arg_tys[i]) {
            return TieBreaker.TieByLiteral
        }
        out = TieBreaker.TieByOpenVar
    }
    return out
}

// Structural specificity of a candidate's declared parameters: the count of concrete type
// constructors, with type variables contributing nothing. The primary ranking key in
// `resolve_overload` - a stand-in for a real constraint system. `deinit(&List($T))` (Ref+Nominal =
// 2) beats the universal `deinit(&$T)` (Ref = 1), and `any(&Dict($K,$V), $F)` beats the iterator
// catch-all `any($I, $F)`.
//
// A position is only scored when its ARGUMENT has a fully-known shape: params past the supplied
// args (defaults the call omitted) and params whose argument still contains an unresolved var (an
// unsuffixed literal, a half-inferred tuple or container) are skipped. An unbound arg unifies with
// anything at zero cost, so scoring its position would steer `s[0]` to `op_index(String,
// Range(usize))` (spec 3) over `op_index(String, usize)` (spec 2). Skipped positions fall back to
// the cost/quantifier keys - the pre-specificity behavior.
fn scheme_specificity(self: &Checker, s: &Scheme, arg_tys: &List(Ty)) u32 {
    let ft = ty_node(self, s.body) match {
        NFunc(f) => Some(f)
        _ => null
    }
    if ft.is_none() {
        return 0
    }
    let f = ft.unwrap()
    let n = if arg_tys.len < f.params.len { arg_tys.len } else { f.params.len }
    let total = 0u32
    for i in 0..n {
        if !ty_has_free_var(self, self.engine.resolve(arg_tys[i])) {
            total = total + ty_specificity(self, self.engine.interner.child_at(f.params, i))
        }
    }
    return total
}

// Whether a (resolved) type still contains an unbound inference var anywhere in its structure.
fn ty_has_free_var(self: &Checker, t: Ty) bool {
    if self.engine.interner.is_ground(t) {
        return false
    }
    return ty_node(self, t) match {
        NVar(_) => true
        NRef(inner) => ty_has_free_var(self, self.engine.resolve(inner))
        NArray(a) => ty_has_free_var(self, self.engine.resolve(a.elem))
        NFunc(f) => ty_has_free_var(self, self.engine.resolve(f.ret))
            or span_has_free_var(self, f.params)
        NTuple(span) => span_has_free_var(self, span)
        NNominal(nn) => span_has_free_var(self, nn.args)
        _ => false
    }
}

fn span_has_free_var(self: &Checker, span: ChildSpan) bool {
    for i in 0..span.len {
        if ty_has_free_var(self, self.engine.resolve(self.engine.interner.child_at(span, i))) {
            return true
        }
    }
    return false
}

fn ty_specificity(self: &Checker, t: Ty) u32 {
    return ty_node(self, t) match {
        NVar(_) => 0u32
        NRef(inner) => 1u32 + ty_specificity(self, inner)
        NArray(a) => 1u32 + ty_specificity(self, a.elem)
        NFunc(f) => 1u32 + ty_specificity(self, f.ret) + span_specificity(self, f.params)
        NNominal(nn) => 1u32 + span_specificity(self, nn.args)
        _ => 1u32
    }
}

fn span_specificity(self: &Checker, span: ChildSpan) u32 {
    let sum = 0u32
    for i in 0..span.len {
        sum = sum + ty_specificity(self, self.engine.interner.child_at(span, i))
    }
    return sum
}

// A candidate's probe outcome, split so the ranking can weigh the parts differently: `coercions`
// counts implicit conversions the arguments needed; `penalty` carries everything that is not a
// conversion (omitted defaulted params, the UFCS receiver adaptation).
pub type ProbeCost = struct {
    coercions: u32
    penalty: u32
    // Bound atoms (RFC-035) the arguments were seen to satisfy: a stricter bound that holds is more
    // specific. An atom on a still-open type counts for nothing.
    held: u32
}

pub fn total(self: ProbeCost) u32 {
    return self.coercions + self.penalty
}

// An argument that does not fit its parameter is retried through the wrapped values `op_deref`
// reaches, by reference first and then by value when that value is copyable, fewest hops first
// (RFC-020): an owner decays to the view it holds, never to a second owner. Unifies the first shape
// that fits and returns the hops it took; null leaves the engine as it was found. `chain` collects
// the hop picks when the caller is committing rather than probing.
fn peel_arg(
    self: &Checker,
    arg: Ty,
    param: Ty,
    span: SourceSpan,
    ctx: &PeelCtx,
    chain: &List(OverloadPick)?,
) usize? {
    let dcands = deref_candidates(self, ctx.vis)
    if dcands.is_none() {
        return null
    }
    let dc = dcands.unwrap()
    defer dc.deinit()
    let current = self.engine.resolve(arg)
    let hops = 0usize
    while hops < 10 {
        let peeled = ty_node(self, current) match {
            NRef(inner) => self.engine.resolve(inner)
            _ => current
        }
        const nominal = ty_node(self, peeled) match { NNominal(_) => true, _ => false }
        if !nominal {
            return null
        }
        let dargs = list(1)
        dargs.push(self.engine.mk_ref(peeled))
        const dpick = resolve_overload(self, &dc, &dargs, span)
        dargs.deinit()
        if dpick.is_none() {
            return null
        }
        hops = hops + 1
        const hop = dpick.unwrap()
        const hop_ret = hop.ret
        if chain.is_some() {
            chain.unwrap().push(hop)
        }
        const dret = self.engine.resolve(hop_ret)
        const inner = ty_node(self, dret) match {
            NRef(i) => self.engine.resolve(i)
            _ => return null
        }
        // The value leg decays an owner to the view it holds, so it is gated on that view being
        // copyable: peeling to a non-copyable value would hand the same resource to two owners.
        if try_unify_arg(self, dret, param) {
            return Some(hops)
        }
        if ty_copyable(self, inner) and try_unify_arg(self, inner, param) {
            return Some(hops)
        }
        current = inner
    }
    return null
}

// Unify inside a checkpoint that is kept on success and rolled back on failure.
fn try_unify_arg(self: &Checker, arg: Ty, param: Ty) bool {
    self.engine.push_checkpoint()
    const ok = self.engine.unify(arg, param) match {
        Unified(_) => true
        _ => false
    }
    if ok {
        self.engine.commit()
    } else {
        self.engine.rollback()
    }
    return ok
}

// Speculatively check one candidate: null when it cannot take these arguments, else its ProbeCost
// (fuller matches win via the omitted-defaults penalty, as in the reference checker).
fn probe_candidate(
    self: &Checker,
    c: &FunctionScheme,
    arg_tys: &List(Ty),
    named: &NamedArgs? = null,
    ufcs_offset: usize = 0usize,
    peel: &PeelCtx? = null,
    span: SourceSpan = none_span(),
) ProbeCost? {
    self.probe_bound_failed = false
    // A bounded candidate keeps its instantiation, to test its bounds against what the arguments
    // bound.
    const bounded = self.fn_bounds.get_ref(c.id).is_some()
    let binds: Dict(VarId, Ty) = dict()
    defer binds.deinit()
    const fn_ty = if bounded { self.engine.specialize_capture(&c.signature, &binds) } else {
        self.engine.specialize(&c.signature)
    }
    let f = ty_node(self, self.engine.resolve(fn_ty)) match {
        NFunc(ft) => ft
        _ => return null
    }
    let n_params = f.params.len
    // Named arguments count toward the arity window and each must name a parameter of THIS
    // candidate; a name it does not declare rules it out.
    let n_named = 0usize
    let slots: List(usize)? = null
    if named.is_some() {
        let na = named.unwrap()
        n_named = na.names.len
        install(&slots, named_param_slots(self, c, na, ufcs_offset))
        if slots.is_none() {
            return null
        }
    }
    let supplied = arg_tys.len + n_named
    if !arity_accepts(c, n_params, supplied) {
        if slots.is_some() {
            let dead = slots.unwrap()
            dead.deinit()
        }
        return null
    }

    let checked = non_variadic_arg_count(c, n_params, arg_tys.len)
    // The element type the variadic tail's surplus arguments land in (the declared parameter is
    // `Slice(T)`).
    let vtail: Ty? = null
    if c.has_variadic and n_params > 0 {
        vtail = variadic_elem(self, self.engine.interner.child_at(f.params, n_params - 1))
    }
    self.engine.push_checkpoint()
    let ok = true
    let cost = 0u32
    let i = 0usize
    while ok and i < checked {
        // The literal candidate-set constraint: a bare `10`'s open var would unify with ANY param -
        // `String` included, and declaration order would commit it. A pending numeric literal may
        // only meet a primitive, an open var (generics), or Option (wrap coercion).
        if is_literal_var(self, arg_tys[i])
            and !literal_can_take(self, self.engine.interner.child_at(f.params, i)) {
            ok = false
        }
        if ok {
            const param = self.engine.interner.child_at(f.params, i)
            self.engine.unify(arg_tys[i], param) match {
                Unified(u) => cost = cost + u.cost
                // The argument does not fit as written: RFC-020 retries it through `op_deref`.
                _ => {
                    const hops = if peel.is_some() and i >= ufcs_offset {
                        peel_arg(self, arg_tys[i], param, span, peel.unwrap(), null)
                    } else {
                        null
                    }
                    if hops.is_some() {
                        cost = cost + 2u32 * (hops.unwrap() as u32)
                    } else {
                        ok = false
                    }
                }
            }
        }
        i = i + 1
    }
    if vtail.is_some() {
        let ve = vtail.unwrap()
        let k = checked
        while ok and k < arg_tys.len {
            self.engine.unify(arg_tys[k], ve) match {
                Unified(u) => cost = cost + u.cost
                _ => ok = false
            }
            k = k + 1
        }
    }
    if slots.is_some() {
        let sl = slots.unwrap()
        let na = named.unwrap()
        let j = 0usize
        while ok and j < sl.len {
            if sl[j] >= n_params {
                ok = false
            } else {
                self.engine.unify(na.tys[j], self.engine.interner.child_at(f.params, sl[j])) match {
                    Unified(u) => cost = cost + u.cost
                    _ => ok = false
                }
            }
            j = j + 1
        }
        sl.deinit()
    }
    let held = 0u32
    if ok and bounded {
        // Inside a satisfaction check `copyable` decides too: the blanket `hash($T) where T:
        // copyable` must not make an owning type `Hash`. At the top level it is left to the drain,
        // which reports it with its derivation.
        const check = check_bounds(self, c.id, Some(&binds), false, self.bound_depth > 0)
        ok = check.failed.is_none()
        self.probe_bound_failed = !ok
        held = check.held
    }
    self.engine.rollback()
    if !ok {
        return null
    }

    let omitted = if supplied < n_params { n_params - supplied } else { 0usize }
    if c.has_variadic and omitted > 0 {
        omitted = omitted - 1
    }
    return Some(ProbeCost { coercions = cost, penalty = (omitted as u32) * 100u32, held = held })
}

// Whether `ty` resolves to the still-open var of a pending numeric literal (`10`, `3.14` with no
// suffix and nothing pinning them yet). Linear scan, bounded: `seal_slot` retires a slot's literals
// once their sweep has run, so the list holds only the preamble entries plus the running slot's
// own.
fn is_literal_var(self: &Checker, ty: Ty) bool {
    let vid = ty_node(self, self.engine.resolve(ty)) match {
        NVar(v) => v
        _ => return false
    }
    for i in 0..self.pending_literals.len {
        let pv = ty_node(self, self.engine.resolve(self.pending_literals[i].ty)) match {
            NVar(v2) => Some(v2)
            _ => null
        }
        if pv.is_some() {
            if pv.unwrap().id == vid.id {
                return true
            }
        }
    }
    return false
}

// What a pending numeric literal's var is allowed to meet in an overload probe: a primitive, an
// open var (a generic's `$T`), or the well-known Option (the wrap coercion pins the literal at the
// payload).
fn literal_can_take(self: &Checker, ty: Ty) bool {
    return ty_node(self, self.engine.resolve(ty)) match {
        NPrim(_) => true
        NVar(_) => true
        NNominal(n) => {
            let id = self.nominals.by_fqn.get(FQN_OPTION)
            id.is_some() and id.unwrap() == n.id
        }
        _ => false
    }
}

// A candidate's signature specialized fresh and viewed as a function.
fn scheme_fn_ty(self: &Checker, s: &Scheme) NFuncNode? {
    return ty_node(self, self.engine.resolve(self.engine.specialize(s))) match {
        NFunc(ft) => Some(ft)
        _ => null
    }
}

// How many leading args unify against declared params: everything up to the variadic tail. Surplus
// variadic args are not element-checked yet - see docs/known-issues.md (Bootstrap Self-Host). The
// element type of a variadic parameter: the declared `..xs: T` lands as `Slice(T)`, so the surplus
// arguments unify with its single type argument. Null when the parameter is not a one-argument
// nominal.
fn variadic_elem(self: &Checker, param: Ty) Ty? {
    return ty_node(self, self.engine.resolve(param)) match {
        NNominal(nn) => if nn.args.len == 1 { Some(self.engine.interner.child_at(
            nn.args,
            0,
        )) } else { null }
        _ => null
    }
}

fn non_variadic_arg_count(c: &FunctionScheme, n_params: usize, n_args: usize) usize {
    let non_variadic = if c.has_variadic { n_params - 1 } else { n_params }
    return if n_args < non_variadic { n_args } else { non_variadic }
}

// `Enum.Variant(args)` or bare `Variant(args)` - payload-carrying enum variant construction. Null
// for every other call shape; the caller falls through to function/indirect call handling. The
// callee is NOT checked as a value on the variant path - a type name has no value binding, so
// checking it would wrongly report `unknown identifier`.
fn variant_call(self: &Checker, call: &CallExpr, arg_tys: &List(Ty)) Ty? {
    let node = self.node_of(call.span)
    return call.callee.* match {
        MemberAccess(ma) => {
            let id = enum_receiver(self, ma.receiver)
            if id.is_none() {
                return null
            }
            const out = construct_variant(self, id.unwrap(), ma.member, arg_tys, call.span, node)
            if out.is_some() {
                record_nominal_ref(self, expr_span(ma.receiver), id.unwrap())
            }
            out
        }
        Identifier(ide) => unqualified_variant_call(self, &ide, arg_tys, call.span, node)
        _ => null
    }
}

// Bare `Variant(args)`: locals and functions win over variant names, so the constructor
// interpretation only fires when the name has neither a value binding nor a visible function
// candidate.
fn unqualified_variant_call(
    self: &Checker,
    ide: &IdentifierExpr,
    arg_tys: &List(Ty),
    span: SourceSpan,
    node: NodeId,
) Ty? {
    if name_is_value_bound(self, ide.name) {
        return null
    }
    let vis = current_visibility(self)
    defer vis.deinit()
    let nid = self.nominals.lookup_variant(ide.name, arg_tys.len, &vis)
    if nid.is_none() {
        return null
    }
    return construct_variant(self, nid.unwrap(), ide.name, arg_tys, span, node)
}

// True when the name resolves as a value - a local binding or a visible function. Values always win
// over variant and type-name interpretations.
fn name_is_value_bound(self: &Checker, name: String) bool {
    if self.env.lookup(name).is_some() {
        return true
    }
    let vis = fn_visibility(self)
    defer vis.deinit()
    return self.functions.lookup(name, &vis) match {
        FnLookFound(_) => true
        _ => false
    }
}

// `Entry(K, V)` - a visible nominal called with type arguments yields the instantiated nominal
// itself; the `Type(T)` coercion lifts it where a reified type parameter expects it.
fn type_instantiation_call(self: &Checker, ide: &IdentifierExpr, arg_tys: &List(Ty)) Ty? {
    if name_is_value_bound(self, ide.name) {
        return null
    }
    let vis = current_visibility(self)
    defer vis.deinit()
    let nid = self.nominals.lookup(ide.name, &vis) match {
        NomLookFound(n) => Some(n)
        _ => null
    }
    if nid.is_none() {
        return null
    }
    let id = nid.unwrap()
    let n_params = self.nominals.get(id).* match {
        NomStruct(s) => s.type_params.len
        NomEnum(e) => e.type_params.len
    }
    if n_params != arg_tys.len {
        return null
    }
    // The arguments are TYPE names, so each already arrived reified (`i32` types as `Type(i32)`);
    // the instantiation wants the types themselves, and the RESULT is what gets reified.
    let args = list(arg_tys.len)
    for i in 0..arg_tys.len {
        args.push(unreify_type(self, arg_tys[i]))
    }
    let inst = mk_nominal(self, id, args)
    // `Type(T)` written out IS the reified form - wrapping it again would make `Type(Type(T))`.
    let type_id = self.nominals.by_fqn.get(FQN_TYPE)
    let is_type_ctor = type_id match {
        Some(tid) => tid == id
        None => false
    }
    if is_type_ctor {
        return Some(inst)
    }
    return Some(reified_type_of(self, inst))
}

// `Type(T)` → `T`; anything else unchanged.
fn unreify_type(self: &Checker, t: Ty) Ty {
    let type_id = self.nominals.by_fqn.get(FQN_TYPE)
    if type_id.is_none() {
        return t
    }
    let nr_opt = ty_node(self, self.engine.resolve(t)) match {
        NNominal(nn) => Some(nn)
        _ => null
    }
    if nr_opt.is_none() {
        return t
    }
    let nr = nr_opt.unwrap()
    if nr.id == type_id.unwrap() and nr.args.len == 1 {
        return self.engine.interner.child_at(nr.args, 0)
    }
    return t
}

// Expression-context if. Without an else the value is void and the then branch's value is
// discarded; with one, the branches must agree.
fn check_if(self: &Checker, if_expr: &IfExpr) Ty {
    let _r = check_expr(self, if_expr.condition)
    let then_ty = check_block(self, if_expr.then_branch)
    let else_ty = if_expr.else_branch match {
        NoElse => return TY_VOID
        Block(b) => check_block(self, b)
        If(nested) => {
            // A chained `else if` is a bare `&IfExpr`, not an `Expr`, so `check_expr`'s record
            // never sees it - record its type here or lowering's `node_ty` defaults the join to i32
            // and an aggregate arm value gets truncated through the block param.
            let t = check_if(self, nested)
            self.results.record_type(self.node_of(nested.span), t)
            t
        }
    }
    return join_types(self, then_ty, else_ty, E_BRANCH_MISMATCH, if_expr.span)
}

// `S { f = v, ... }` - the literal's type is the resolved nominal `S`; each initializer is unified
// against its declared field type (so an unsuffixed
// literal resolves and a mismatch is reported). An anonymous `.{ … }` (no
// type) defers to a fresh var until record literals land.
fn check_struct_lit(self: &Checker, lit: &StructLiteralExpr) Ty {
    if lit.type_expr.is_none() {
        // The anonymous form types as a fresh var the context binds (return type, annotation, call
        // parameter). Field constraints can't apply until that binding exists, so the initializers
        // are parked and `resolve_anon_literals` unifies them against the nominal's field types
        // once inference settles.
        let recs: List(AnonFieldRec) = list(lit.fields.len)
        for &fi in lit.fields {
            let v = check_field_value(self, fi)
            recs.push(AnonFieldRec { name = fi.name, ty = v, span = fi.span })
        }
        let anon_var = self.engine.fresh_var()
        self.pending_anons.push(PendingAnon { ty = anon_var, fields = move recs })
        return anon_var
    }
    let ty = resolve_type_expr(self, lit.type_expr.unwrap())
    if is_context_ty(self, ty) {
        push_diag_e(
            self,
            lit.span,
            E_CONTEXT_BASE,
            from_view("a `Context` is made by `context`, not by a struct literal"),
        )
        for &fc in lit.fields {
            let _vc = check_field_value(self, fc)
        }
        return TY_ERROR
    }
    let is_structish = ty_node(self, ty) match {
        NNominal(nn) => !is_enum_id(self, nn.id)
        NVar(_) => true
        NError => true
        _ => false
    }
    if !is_structish {
        push_diag_e(
            self,
            lit.span,
            E_NOT_A_STRUCT,
            from_view("struct-literal syntax requires a struct type"),
        )
        for &fi0 in lit.fields {
            let _v0 = check_field_value(self, fi0)
        }
        return TY_ERROR
    }

    // A generic struct constructed by NAME must spell its type arguments: `Pair(i64) { ... }`.
    // Inference from fields belongs to the anonymous `.{ ... }` form. Without this check the
    // literal records an under-instantiated nominal (`Pair` with no arguments), which no downstream
    // layout query can size - the reference checker rejects the same shape with E2019.
    let missing = generic_struct_missing_args(self, ty)
    if missing.is_some() {
        let n = missing.unwrap()
        const msg = $"generic struct `{n}` requires type arguments, use `{n}(...)` or `.{{ ... }}`"
        push_diag_e(self, lit.span, E_GENERIC_NEEDS_ARGS, msg)
        // Field expressions still check for their own errors; the literal itself has no usable
        // type.
        for i in 0..lit.fields.len {
            let _v = check_field_value(self, &lit.fields[i])
        }
        return TY_ERROR
    }

    for &fi in lit.fields {
        let v = check_field_value(self, fi)
        let fty = struct_field_lookup(self, ty, fi.name)
        if fty.is_some() {
            record_init_ref(self, ty, fi.name, fi.span)
            const o = self.engine.unify(v, fty.unwrap())
            report_unify(self, &o, E_TYPE_MISMATCH, fi.span)
        }
    }
    let present: List(String) = list(lit.fields.len)
    defer present.deinit()
    for &fi2 in lit.fields {
        present.push(fi2.name)
    }
    report_missing_fields(self, ty, &present, lit.span)
    return ty
}

// Strict construction (spec 2): every field of a struct is assigned by the literal. A field left
// out would take whatever its slot's zero bytes mean - a value nobody wrote - and a field added to
// the type later would do that at every site already written, silently.
fn report_missing_fields(self: &Checker, ty: Ty, present: &List(String), span: SourceSpan) {
    let nn = ty_node(self, ty) match {
        NNominal(n) => n
        _ => return
    }
    let sd = self.nominals.get(nn.id).* match {
        NomStruct(st) => move st
        _ => return
    }
    for i in 0..sd.fields.len {
        let found = false
        for j in 0..present.len {
            if present[j] == sd.fields[i].name {
                found = true
            }
        }
        if !found {
            push_diag_e(
                self,
                span,
                E_MISSING_FIELD,
                $"struct literal missing field `{sd.fields[i].name}`",
            )
        }
    }
}

// The struct's display name when `ty` is a nominal struct instantiated with fewer (or more) type
// arguments than its declaration has parameters; null when the instantiation is well-formed or `ty`
// isn't a struct.
fn generic_struct_missing_args(self: &Checker, ty: Ty) String? {
    let nn = ty_node(self, ty) match {
        NNominal(n) => n
        _ => return null
    }
    let sd = self.nominals.get(nn.id).* match {
        NomStruct(s) => move s
        _ => return null
    }
    if nn.args.len == sd.type_params.len {
        return null
    }
    return Some(short_name_of(sd.fqn, last_dot(sd.fqn)))
}

// The value of a field initializer: the explicit `f = expr`, or - for shorthand `S { f }` - the
// in-scope binding named like the field.
fn check_field_value(self: &Checker, fi: &StructFieldInit) Ty {
    if fi.value.is_some() {
        return check_expr(self, fi.value.unwrap())
    }
    let id = IdentifierExpr { span = fi.span, name = fi.name }
    return check_identifier(self, &id)
}

// `recv.member` - when the receiver is a struct with a field of that name, the access yields the
// field's (substituted) type. Otherwise it defers to a fresh var: member syntax also bases UFCS
// calls, which resolve elsewhere.
fn check_member(self: &Checker, ma: &MemberAccessExpr) Ty {
    // Qualified enum-variant access (`Ord.Less`) is resolved before the receiver is checked as a
    // value: a type name has no value binding, so checking it would wrongly report `unknown
    // identifier`.
    let ev = enum_variant_access(self, ma)
    if ev.is_some() {
        return ev.unwrap()
    }

    let recv = check_expr(self, ma.receiver)
    if is_context_ty(self, recv) {
        return context_member(self, ma)
    }
    let fty = struct_field_lookup(self, recv, ma.member)
    if fty.is_some() {
        record_field_ref(self, recv, ma.member, tail_span(ma.span, ma.member.len))
        return fty.unwrap()
    }
    // `let a = .{ x, y }` - nothing has pinned the literal's var yet (`resolve_anon_literals`
    // settles it after the body), but the record it describes already knows its fields, so the
    // access types now.
    let pf = pending_anon_field(self, recv, ma.member)
    if pf.is_some() {
        return pf.unwrap()
    }
    let tp = tuple_projection(self, recv, ma.member)
    if tp.is_some() {
        return tp.unwrap()
    }
    let am = array_member(self, recv, ma.member)
    if am.is_some() {
        return am.unwrap()
    }
    let dm = member_deref_retry(self, ma, recv)
    if dm.is_some() {
        return dm.unwrap()
    }
    // A concrete struct receiver with no such field is E2014. An unresolved receiver, an enum, or a
    // primitive is left alone: member syntax over those is UFCS, resolved elsewhere.
    if struct_without_field(self, recv, ma.member) {
        push_diag_e(self, ma.span, E_FIELD_NOT_FOUND, $"no field `{ma.member}` on this type")
        return TY_ERROR
    }
    // An open receiver: the access is parked and its placeholder unified once the receiver settles.
    const placeholder = self.engine.fresh_var()
    if self.engine.is_var(self.engine.zonk(recv)) {
        self.pending_members.push(PendingMember {
            span = ma.span,
            recv = recv,
            member = ma.member,
            placeholder = placeholder,
            module = self.current_module,
        })
    }
    return placeholder
}

// Finish every parked member access whose receiver has settled since: look the field up on the
// receiver's nominal and unify the placeholder with its type, so a generic pick made through the
// placeholder (`entry.prev.is_some()`) closes its `$T`. Runs before and after a body scope's drain,
// since the drain is what pins a lambda parameter; a receiver still open afterwards stays parked
// (its placeholder a var, which whatever needed it reports) until the scope discards it.
fn resolve_pending_members(self: &Checker) {
    let parked = replace(&self.pending_members, list(0))
    for &pm in parked {
        const z = self.engine.zonk(pm.recv)
        if self.engine.is_var(z) {
            self.pending_members.push(pm.*)
            continue
        }
        let saved = self.current_module
        self.current_module = pm.module
        const fty = struct_field_lookup(self, z, pm.member)
        if fty.is_some() {
            record_field_ref(self, z, pm.member, tail_span(pm.span, pm.member.len))
            const o = self.engine.unify(pm.placeholder, fty.unwrap())
            report_unify(self, &o, E_TYPE_MISMATCH, pm.span)
        } else if struct_without_field(self, z, pm.member) {
            push_diag_e(self, pm.span, E_FIELD_NOT_FOUND, $"no field `{pm.member}` on this type")
        }
        self.current_module = saved
    }
    parked.deinit()
}

// The field type an as-yet-unpinned anonymous literal records for `name`. Null when `recv` is not
// one of the parked literals' vars.
fn pending_anon_field(self: &Checker, recv: Ty, name: String) Ty? {
    let vid = ty_node(self, self.engine.resolve(recv)) match {
        NVar(v) => v
        _ => return null
    }
    for i in 0..self.pending_anons.len {
        let pv = ty_node(self, self.engine.resolve(self.pending_anons[i].ty)) match {
            NVar(v2) => Some(v2)
            _ => null
        }
        if pv.is_none() {
            continue
        }
        if pv.unwrap().id != vid.id {
            continue
        }
        for &rec in self.pending_anons[i].fields {
            if rec.name == name {
                return Some(rec.ty)
            }
        }
    }
    return null
}

// True when `recv` peels to a struct nominal that declares no field of this name - the shape E2014
// describes.
fn struct_without_field(self: &Checker, recv: Ty, name: String) bool {
    let peeled = peel_refs(self, recv)
    let nid = ty_node(self, peeled) match {
        NNominal(nn) => Some(nn.id)
        _ => null
    }
    if nid.is_none() {
        return false
    }
    let sd = self.nominals.get(nid.unwrap()).* match {
        NomStruct(s) => Some(move s)
        _ => null
    }
    if sd.is_none() {
        return false
    }
    const __sd_v = sd.unwrap()
    return !field_named(&__sd_v.fields, name)
}

// `w.x` where `w: Wrapper(Point)` declares `op_deref(&Wrapper($T)) &T`: field access peels the same
// `op_deref` hops UFCS calls do (`deref_retry`), so a smart pointer forwards member syntax as well
// as method syntax. The winning chain is recorded on the MEMBER node - lowering calls each hop
// instead of geping into the wrapper's own layout, which would read at the wrong offset.
fn member_deref_retry(self: &Checker, ma: &MemberAccessExpr, recv_ty: Ty) Ty? {
    return member_deref_retry_at(self, ma.member, ma.span, recv_ty)
}

// Resolves `member` on `recv_ty` through `op_deref` hops and records the chain on `span`, the node
// lowering will ask at. `member_deref_retry` is the spelled-member case; this one also serves
// members the source does not spell, such as the `len` an open range `xs[a..]` reads for its end.
fn member_deref_retry_at(self: &Checker, member: String, span: SourceSpan, recv_ty: Ty) Ty? {
    let vis = fn_visibility(self)
    defer vis.deinit()
    let dcands = self.functions.lookup("op_deref", &vis) match {
        FnLookFound(c) => Some(move c)
        _ => null
    }
    if dcands.is_none() {
        return null
    }
    let dc = dcands.unwrap()
    defer dc.deinit()

    let chain: List(OverloadPick) = list(1)
    defer chain.deinit()

    let current = self.engine.resolve(recv_ty)
    let depth = 0usize
    loop {
        if depth >= 10 {
            return null
        }
        depth = depth + 1

        let peeled = ty_node(self, current) match {
            NRef(inner) => self.engine.resolve(inner)
            _ => current
        }
        let is_nominal = ty_node(self, peeled) match { NNominal(_) => true, _ => false }
        if !is_nominal {
            return null
        }

        let dargs = list(1)
        dargs.push(self.engine.mk_ref(peeled))
        let dpick = resolve_overload(self, &dc, &dargs, span)
        dargs.deinit()
        if dpick.is_none() {
            return null
        }
        const hop = dpick.unwrap()
        const hop_ret = hop.ret
        chain.push(hop)

        let dret = self.engine.resolve(hop_ret)
        let inner = ty_node(self, dret) match {
            NRef(i) => self.engine.resolve(i)
            _ => return null
        }

        let fty = struct_field_lookup(self, inner, member)
        if fty.is_some() {
            commit_deref_chain(self, &chain, chain.len, span)
            return fty
        }

        current = inner
    }
    return null
}

// `arr.len` / `arr.ptr` on a fixed array (one reference peeled): usize and `&elem` - the
// checker-side mirror of lowering's constant fold; left untyped the member's var reached `ty_to_ir`
// under a cast.
fn array_member(self: &Checker, recv: Ty, member: String) Ty? {
    let r = self.engine.resolve(recv)
    let peeled = ty_node(self, r) match {
        NRef(inner) => self.engine.resolve(inner)
        _ => r
    }
    let arr = ty_node(self, peeled) match {
        NArray(a) => Some(a)
        _ => null
    }
    if arr.is_none() {
        return null
    }
    if member == "len" {
        return Some(prim_of(PrimitiveKind.USize))
    }
    if member == "ptr" {
        return Some(self.engine.mk_ref(arr.unwrap().elem))
    }
    return null
}

// `t.0` / `t.1` - positional projection on a tuple-typed receiver (one reference peeled). Null for
// non-tuples, non-numeric members, and out-of-range indices - those fall through to UFCS
// resolution.
fn tuple_projection(self: &Checker, recv: Ty, member: String) Ty? {
    let r = self.engine.resolve(recv)
    let peeled = ty_node(self, r) match {
        NRef(inner) => self.engine.resolve(inner)
        _ => r
    }
    let elems = ty_node(self, peeled) match {
        NTuple(es) => es
        _ => return null
    }
    let idx = parse_decimal(member)
    if idx.is_none() {
        return null
    }
    if idx.unwrap() >= elems.len {
        return null
    }
    return Some(self.engine.interner.child_at(elems, idx.unwrap()))
}

// Qualified enum-variant access `EnumName.Variant`: a bare receiver naming an in-scope enum whose
// `member` is one of its payload-less variants yields the enum's nominal type. Null for every other
// shape, leaving field access and UFCS untouched. Payload-carrying variants only construct through
// call syntax - see `variant_call`.
fn enum_variant_access(self: &Checker, ma: &MemberAccessExpr) Ty? {
    let id = enum_receiver(self, ma.receiver)
    if id.is_none() {
        return null
    }
    const out = construct_nullary(self, id.unwrap(), ma.member, ma.span)
    if out.is_some() {
        record_nominal_ref(self, expr_span(ma.receiver), id.unwrap())
    }
    return out
}

// The nominal a bare-identifier receiver names, when it is not shadowed by a value binding. Locals
// win: `x.foo` on a local `x` is field access or UFCS even if a type `x` is also in scope.
fn enum_receiver(self: &Checker, recv: &Expr) NominalId? {
    let name = recv.* match {
        Identifier(ide) => Some(ide.name)
        _ => null
    }
    if name.is_none() {
        return null
    }
    if self.env.lookup(name.unwrap()).is_some() {
        return null
    }

    let vis = current_visibility(self)
    defer vis.deinit()
    return self.nominals.lookup(name.unwrap(), &vis) match {
        NomLookFound(id) => Some(id)
        _ => null
    }
}

fn construct_nullary(self: &Checker, id: NominalId, vname: String, span: SourceSpan) Ty? {
    let empty = list(0)
    let out = construct_variant(self, id, vname, &empty, span, self.node_of(span))
    empty.deinit()
    return out
}

// Construct an enum variant: fresh type args for the enum's params, the variant's payload types
// substituted against them, and each argument unified with its payload. Null when the nominal is
// not an enum, names no such variant, or the argument count differs - callers fall through to the
// other call forms. On success the variant target is recorded for lowering and go-to-definition.
fn construct_variant(
    self: &Checker,
    id: NominalId,
    vname: String,
    arg_tys: &List(Ty),
    span: SourceSpan,
    node: NodeId,
) Ty? {
    let ed = self.nominals.get(id).* match {
        NomEnum(e) => Some(move e)
        _ => null
    }
    if ed.is_none() {
        return null
    }
    let e = ed.unwrap()

    let vnum = 0u32
    let found = false
    for i in 0..e.variants.len {
        if !found and e.variants[i].name == vname {
            vnum = i as u32
            found = true
        }
    }
    if !found {
        return null
    }
    let payloads = &e.variants[vnum as usize].payloads
    if payloads.len != arg_tys.len {
        return null
    }

    let subst = dict()
    let args = list(e.type_params.len)
    for k in 0..e.type_params.len {
        let fresh = self.engine.fresh_var()
        subst.set(e.type_params[k], fresh)
        args.push(fresh)
    }
    for v in e.assoc_params {
        subst.set(v, self.engine.fresh_var())
    }
    for i in 0..payloads.len {
        let pty = self.engine.substitute_shared(payloads[i], &subst)
        const o = self.engine.unify(arg_tys[i], pty)
        report_unify(self, &o, E_TYPE_MISMATCH, span)
    }
    subst.deinit()
    self.results.record_target(node, ResolvedTarget.RtEnumVariant(id, vnum))
    return Some(mk_nominal(self, id, args))
}

// A struct field's declared type by name, substituted against the receiver instance's type
// arguments - a read must never bind the definition's shared type-param vars. Null when the
// (zonked, one-reference-peeled) type is not a struct or has no such field.
fn struct_field_lookup(self: &Checker, recv: Ty, name: String) Ty? {
    let z = self.engine.zonk(recv)
    let peeled = peel_refs(self, z)
    let nr_opt = ty_node(self, peeled) match {
        NNominal(n) => Some(n)
        _ => null
    }
    if nr_opt.is_none() {
        return null
    }
    let nr = nr_opt.unwrap()
    // A `Type(T)` value IS a TypeInfo (minimal RTTI) - field access reads TypeInfo's definition, so
    // `ty.size` types as usize.
    let is_type_handle = self.nominals.get(nr.id).* match {
        NomStruct(sd0) => sd0.fqn == FQN_TYPE
        _ => false
    }
    if is_type_handle {
        let ti = self.nominals.by_fqn.get(FQN_TYPE_INFO)
        ti match {
            Some(tid) => {
                nr = NNominalNode { id = tid, args = ChildSpan { start = 0u32, len = 0u32 } }
            }
            None => {}
        }
    }
    let def_node = self.nominals.get(nr.id)
    let sd_opt = def_node.* match {
        NomStruct(s) => Some(move s)
        _ => null
    }
    if sd_opt.is_none() {
        return null
    }
    let sd = sd_opt.unwrap()
    // `Context`'s fields are its layout (`assemble_context`); a use resolves through the context
    // registry instead.
    if sd.fqn == FQN_CONTEXT {
        return null
    }
    for i in 0..sd.fields.len {
        if sd.fields[i].name == name {
            if sd.type_params.len == 0 or sd.type_params.len != nr.args.len {
                return Some(sd.fields[i].ty)
            }
            let subst = member_subst(self, peeled, &sd.type_params, &sd.assoc_params, nr.args)
            let out = self.engine.substitute_shared(sd.fields[i].ty, &subst)
            subst.deinit()
            return Some(out)
        }
    }
    return null
}

// ─────────────────────────────────────────────────────────────────────
// Top-level driver
// ─────────────────────────────────────────────────────────────────────

// Nominal type from a scratch argument list - the list is freed here, the table keeps the shape
// (same ownership contract as `mk_func`).
fn mk_nominal(self: &Checker, id: NominalId, args: move List(Ty)) Ty {
    const t = self.engine.interner.nominal_of(id, &args)
    args.deinit()
    return t
}

// Tuple type from a scratch element list - the list is freed here.
fn mk_tuple(self: &Checker, elems: move List(Ty)) Ty {
    const t = self.engine.interner.tuple_of(&elems)
    elems.deinit()
    return t
}

// The shape behind a handle - checker-side shorthand.
fn ty_node(self: &Checker, t: Ty) TyNode {
    return self.engine.interner.node(t)
}

// Zonk a lambda record's types once inference settled; a still-open parameter or return type means
// nothing anywhere pinned the lambda - the reference's "no-context lambda" error (E2001 here).
fn zonk_lambda_info(self: &Checker, info: &LambdaInfo) LambdaInfo {
    let ps: List(Ty) = list(info.params.len)
    for i in 0..info.params.len {
        ps.push(self.engine.zonk(info.params[i]))
    }
    let ret = self.engine.zonk(info.ret)
    let caps: List(CaptureRec) = list(info.captures.len)
    for i in 0..info.captures.len {
        caps.push(CaptureRec {
            name = info.captures[i].name,
            decl = info.captures[i].decl,
            ty = self.engine.zonk(info.captures[i].ty),
        })
    }
    if !sig_concrete(self, &ps, ret) {
        push_diag_e(
            self,
            info.span,
            E_UNINFERRED,
            from_view(
                "cannot infer the lambda's parameter or return types; annotate them or use the lambda where the types are pinned",
            ),
        )
    }
    return LambdaInfo {
        span = info.span,
        params = move ps,
        ret = ret,
        captures = move caps,
        closure_id = info.closure_id,
        symbol = from_view(info.symbol.view),
    }
}

// Rebuild the active result set's lambda table with zonked entries. The old table is abandoned to
// the allocator, like `replace_node_types`; the symbol buffers carry over by view-stable copy.
fn zonk_lambda_table(self: &Checker) {
    if self.results.lambdas.len() == 0 {
        return
    }
    let zl: Dict(NodeId, LambdaInfo) = dict()
    for e in self.results.lambdas {
        // The entry is lent: `zonk_lambda_info` copies the symbol buffer it carries over, and the
        // old table is abandoned to the allocator whole.
        zl.set(e.key, zonk_lambda_info(self, &e.value))
    }
    self.results.replace_lambdas(zl)
}

// Zonk the global closure table and each closure nominal's registry fields (capture types recorded
// mid-inference; layout reads the registry). Runs once, at the end of `check_all`, while the engine
// is still live.
fn zonk_closures(self: &Checker) {
    if self.closures.len() == 0 {
        return
    }
    let zc: Dict(NominalId, ClosureSig) = dict()
    for e in self.closures {
        // Lent, like the lambda table: the zonked copy takes its own symbol buffer.
        const key: NominalId = e.key
        const cs: &ClosureSig = &e.value
        let ps: List(Ty) = list(cs.params.len)
        for i in 0..cs.params.len {
            ps.push(self.engine.zonk(cs.params[i]))
        }
        zc.set(
            key,
            ClosureSig {
                params = move ps,
                ret = self.engine.zonk(cs.ret),
                symbol = from_view(cs.symbol.view),
                lambda_node = cs.lambda_node,
            },
        )

        // Registry fields: rebuild the struct def with zonked capture types.
        let d = self.nominals.get(key)
        d.* match {
            NomStruct(sd) => {
                let zfields: List(Field) = list(sd.fields.len)
                for i in 0..sd.fields.len {
                    zfields.push(Field {
                        name = sd.fields[i].name,
                        ty = self.engine.zonk(sd.fields[i].ty),
                        decl_span = sd.fields[i].decl_span,
                        owned = sd.fields[i].owned,
                    })
                }
                let tps: List(VarId) = list(sd.type_params.len)
                tps.push_all(sd.type_params.as_slice())
                let aps: List(VarId) = list(sd.assoc_params.len)
                aps.push_all(sd.assoc_params.as_slice())
                let updated = StructDef {
                    fqn = sd.fqn,
                    module = sd.module,
                    is_pub = sd.is_pub,
                    type_params = move tps,
                    assoc_params = move aps,
                    fields = move zfields,
                    decl_span = sd.decl_span,
                    deprecation = sd.deprecation,
                    is_simd = sd.is_simd,
                    is_foreign = sd.is_foreign,
                }
                self.nominals.put(key, NominalDef.NomStruct(move updated))
            }
            _ => {}
        }
    }
    self.closures = move zc
}

// Drain the parked overloaded-name-as-value sites of the scope that
// just settled (ticket 019 §4): a slot whose var pinned to a concrete
// Func shape picks the overload those parameter types select, records the winner on the node, and
// unifies the return. A slot nothing pinned stays a fresh var - its consumer refuses at lowering.
fn resolve_fn_name_values(self: &Checker) {
    let pend = replace(&self.pending_fn_names, list(0))
    for &pn in pend {
        let z = self.engine.resolve(pn.ty)
        let ft = ty_node(self, z) match {
            NFunc(f) => Some(f)
            _ => null
        }
        if ft.is_none() {
            continue
        }
        let f = ft.unwrap()
        let fparams: List(Ty) = list(f.params.len)
        for i in 0..f.params.len {
            fparams.push(self.engine.interner.child_at(f.params, i))
        }
        defer fparams.deinit()

        let saved = self.current_module
        self.current_module = pn.module
        let vis = fn_visibility(self)
        defer vis.deinit()
        let cands = self.functions.lookup(pn.name, &vis) match {
            FnLookFound(c) => Some(move c)
            _ => null
        }
        if cands.is_some() {
            let cl = cands.unwrap()
            let pick = resolve_overload(self, &cl, &fparams, pn.span)
            cl.deinit()
            pick match {
                Some(w) => {
                    if decl_moves(self, w.id) != f.moves {
                        push_diag_e(
                            self,
                            pn.span,
                            E_TYPE_MISMATCH,
                            $"`{pn.name}` does not have the function type this slot requires: its parameters differ in `move`",
                        )
                    }
                    self.results.record_target(
                        self.node_of(pn.span),
                        ResolvedTarget.RtFunction(w.id),
                    )
                    note_pending(self, pn.span, false, &w)
                    const o = self.engine.unify(f.ret, w.ret)
                    report_unify(self, &o, E_TYPE_MISMATCH, pn.span)
                }
                // Function types match EXACTLY - there is no coercion between `fn(i32) i32` and
                // `fn(i64) i64` (E2011). Left silent, the name would reach lowering with no target
                // and refuse the whole function instead.
                None => push_diag_e(
                    self,
                    pn.span,
                    E_NO_OVERLOAD,
                    $"no overload of `{pn.name}` has the function type this slot requires",
                )
            }
        }
        self.current_module = saved
    }
    pend.deinit()
}

// Re-zonk the stored signature of every specialization THIS demand instantiated. Lowering mangles
// the spec's C symbol from these types and `sig_lowerable` gates on them, so a var left in one is
// the difference between an emitted function and a silently dropped one. Carried entries are
// skipped (RFC-022 5f): the demand that instantiated one ran this pass over it, and a reuse
// requires a concrete final signature, so there is nothing left to resolve - the sweep is scoped to
// the fresh entries instead of the whole program.
// Solves every ground instance of a definition whose fields name associated types (RFC-036) that
// layout and lowering can meet: those in the program's and the specializations' tables, and,
// through the field types of every instance met, those nested inside them.
fn solve_all_instances(self: &Checker, zonked: &Dict(NodeId, Ty)) {
    if !any_assoc_defs(self) {
        return
    }
    let work: List(Ty) = list(zonked.len())
    defer work.deinit()
    for e in zonked {
        work.push(e.value)
    }
    for i in 0..(self.specs.next_id as usize) {
        const found = self.specs.find(i as SpecId)
        if found.is_none() {
            continue
        }
        const sp = found.unwrap()
        work.push_all(sp.concrete_params.as_slice())
        work.push(sp.concrete_return)
        for e in sp.overlay.node_types {
            work.push(e.value)
        }
    }
    let seen: Set(Ty) = set()
    defer seen.deinit()
    loop {
        const t = work.pop()
        if t.is_none() {
            break
        }
        if seen.contains(t.unwrap()) {
            continue
        }
        seen.add(t.unwrap())
        push_type_children(self, t.unwrap(), &work)
    }
}

// `is_copyable`, with the instances inside `t` whose fields name associated types solved first:
// their fields' types are what the answer depends on.
fn ty_copyable(self: &Checker, t: Ty) bool {
    solve_within(self, t)
    return self.engine.is_copyable(t)
}

fn solve_within(self: &Checker, t: Ty) {
    if !self.assoc_defs {
        return
    }
    let work: List(Ty) = list(4)
    defer work.deinit()
    work.push(self.engine.zonk(t))
    let seen: Set(Ty) = set()
    defer seen.deinit()
    loop {
        const next = work.pop()
        if next.is_none() {
            break
        }
        if seen.contains(next.unwrap()) {
            continue
        }
        seen.add(next.unwrap())
        push_type_children(self, next.unwrap(), &work)
    }
}

fn any_assoc_defs(self: &Checker) bool {
    for i in 0..(self.nominals.next_id as usize) {
        const def = self.nominals.find(i as NominalId)
        if def.is_none() {
            continue
        }
        const n = def.unwrap().* match {
            NomStruct(sd) => sd.assoc_params.len
            NomEnum(ed) => ed.assoc_params.len
        }
        if n > 0 {
            return true
        }
    }
    return false
}

// The types directly inside `t`, a nominal instance's substituted field and payload types included.
fn push_type_children(self: &Checker, t: Ty, work: &List(Ty)) {
    ty_node(self, t) match {
        NRef(inner) => work.push(inner)
        NArray(a) => work.push(a.elem)
        NTuple(span) => work.push_all(self.engine.interner.child_ids(span))
        NRecord(rec) => work.push_all(self.engine.interner.child_ids(rec.tys))
        NFunc(f) => {
            work.push_all(self.engine.interner.child_ids(f.params))
            work.push(f.ret)
        }
        NNominal(nn) => push_member_types(self, t, &nn, work)
        _ => {}
    }
}

fn push_member_types(self: &Checker, t: Ty, nn: &NNominalNode, work: &List(Ty)) {
    work.push_all(self.engine.interner.child_ids(nn.args))
    if nn.args.len == 0 {
        return
    }
    self.nominals.get(nn.id).* match {
        NomStruct(sd) => {
            let subst = member_subst(self, t, &sd.type_params, &sd.assoc_params, nn.args)
            for &f in sd.fields {
                work.push(self.engine.substitute_shared(f.ty, &subst))
            }
            subst.deinit()
        }
        NomEnum(ed) => {
            let subst = member_subst(self, t, &ed.type_params, &ed.assoc_params, nn.args)
            for &v in ed.variants {
                for p in v.payloads {
                    work.push(self.engine.substitute_shared(p, &subst))
                }
            }
            subst.deinit()
        }
    }
}

fn zonk_specializations(self: &Checker) {
    for i in 0..(self.specs.next_id as usize) {
        let found = self.specs.find(i as SpecId)
        if found.is_none() {
            continue
        }
        let sp = found.unwrap()
        if sp.harvested {
            continue
        }
        let ps: List(Ty) = list(sp.concrete_params.len)
        let changed = false
        for k in 0..sp.concrete_params.len {
            const z = self.engine.zonk(sp.concrete_params[k])
            changed = changed or z != sp.concrete_params[k]
            ps.push(z)
        }
        let r = self.engine.zonk(sp.concrete_return)
        changed = changed or r != sp.concrete_return
        self.specs.set_signature(sp.id, ps, r)
        // A signature that moved carried the open var into the body too: the overlay was zonked at
        // the end of `instantiate`, before the caller's drain pinned it (`is_some(&Option($T))` on
        // a lambda parameter's field, settled only by the callee's own instantiation), and a var
        // left there reaches layout. Re-zonk the body under the settled engine.
        if changed {
            let zonked: Dict(NodeId, Ty) = dict(sp.overlay.node_types.len())
            for entry in sp.overlay.node_types {
                zonked.set(entry.key, self.engine.zonk(entry.value))
            }
            sp.overlay.replace_node_types(zonked)
        }
    }
}

// `order` is the sequence to visit modules in, dependencies before dependents. It decides the ids
// every phase hands out, so the same module set and the same order give the same result. `null`
// means source order. `recollect[i]` asks for module i's type names to be gathered from its source
// again; a false entry keeps the names a previous demand on this checker left behind. No list at
// all collects every module, which is what a checker that has never run a demand needs.
// ─────────────────────────────────────────────────────────────────────
// Ownership - liveness for non-copyable values (RFC-028)
// ─────────────────────────────────────────────────────────────────────

// A binding that has been moved. A list rather than a set: a body moves a handful of bindings at
// most, and a branch merge is a copy of the whole thing.
type MovedRec = struct {
    decl: NodeId
    // "" for the whole binding, else the moved field's path below it (`log`, `a.log`). A view into
    // `OwnPass.paths`.
    path: String
}

// One registered `defer`, with the scope depth its body runs at the end of.
type DeferRec = struct {
    expr: &Expr
    scope: usize
}

// What an expression flows into (RFC-033). Nothing set is a read: an operand, a discarded value, an
// argument or receiver that only reads.
type OwnSlot = struct {
    // A by-value destination - a binding, a struct literal field, an element, a variant payload -
    // where a copy of a non-copyable place is spelled `move`.
    value: bool
    // A `move` parameter, which takes ownership of what fills it.
    consumes: bool
    // The function's result, where a returned binding can only move.
    returns: bool
    // A `match` scrutinee, which its arms take apart. It reads a place and owns a temporary.
    owner: bool
}

fn own_read() OwnSlot {
    return .{ value = false, consumes = false, returns = false, owner = false }
}

fn own_value() OwnSlot {
    return .{ value = true, consumes = false, returns = false, owner = false }
}

fn own_consuming() OwnSlot {
    return .{ value = false, consumes = true, returns = false, owner = false }
}

fn own_returning() OwnSlot {
    return .{ value = false, consumes = false, returns = true, owner = false }
}

fn own_owning() OwnSlot {
    return .{ value = false, consumes = false, returns = false, owner = true }
}

fn own_needs_value(slot: OwnSlot) bool {
    return slot.value or slot.consumes or slot.returns
}

// The walk's state. `moved` is the lattice; everything else is control-flow bookkeeping.
type OwnPass = struct {
    moved: List(MovedRec)
    // Storage for the field paths `moved` refers to.
    paths: List(OwnedString)
    defers: List(DeferRec)
    // Moved sets carried out of the innermost loop, by `break` and by `continue` respectively. A
    // break feeds the loop's exit; a continue feeds the next iteration's entry.
    escaped: List(MovedRec)
    continued: List(MovedRec)
    scope: usize
    loop_scope: usize
    in_loop: bool
    // Control left this path, so the rest of the block is unreachable and its state does not reach
    // the next merge.
    diverged: bool
    // Off for a loop's first pass, which only collects the state the back edge carries.
    report: bool
    // Set while a defer body is being walked. A `return` inside one has no return path of its own
    // (E2091), so it fires nothing further - and without the guard it would fire the body it is
    // written in.
    firing: bool
    // Nodes already reported on, so a defer body checked on several exit paths yields one
    // diagnostic rather than one per path.
    seen: Set(NodeId)
    // By-value parameters declared without `move`, by declaration node: the function reads them and
    // owns nothing (rule 3). In a lambda body, also the captures of names lent to the enclosing
    // body.
    lent: List(NodeId)
    // A lambda body's other captures: references to bindings the enclosing body owns, which the
    // lambda may read and write but not take the value out of.
    captured: List(NodeId)
    // `&move T` parameters, by declaration node: the body may take the value out of each, and must
    // leave one behind before it returns (RFC-033).
    slots: List(NodeId)
    // Under a rigid check: bindings handed to a call that did not resolve, which may have consumed
    // them. Whether they are still live depends on what `T` turns out to be.
    uncertain: List(NodeId)
    // Names a pattern bound into storage the function does not own (spec 7.5: an aggregate binding
    // names the scrutinee's storage). None may be moved out; under a lent parameter they also only
    // read, like `lent`.
    borrowed: List(BorrowedRec)
    // The function value a `move` argument is being handed to, "" for a declared function.
    taker: String
}

type BorrowedRec = struct {
    decl: NodeId
    // The scrutinee's root name, "" when it has none (an element, storage behind a reference).
    from: String
    // Bound under a parameter without `move`: no share or write either.
    read_only: bool
}

// Liveness over the body's control flow. Runs once the body is checked, so every node has a type
// and every call a target; nothing here unifies.
//
// ponytail: a loop body is walked twice, so the cost is 2^(loop nesting depth). Bodies nested more
// than two or three deep do not occur; if one does, cache the first pass's effect per body node.
//
// `params` are the body's parameters, null for a `test {}` block; `returns` says whether the body's
// trailing expression is the function's value.
fn own_check_body(self: &Checker, body: &BlockExpr, params: FunctionParam[]?, returns: bool) {
    let lent: List(NodeId) = list(0)
    let slots: List(NodeId) = list(0)
    params match {
        Some(ps) => {
            own_collect_lent(self, &lent, ps)
            own_collect_slots(self, &slots, ps)
        }
        None => {}
    }
    own_run(self, body, lent, list(0), returns, slots)
}

fn own_collect_slots(self: &Checker, slots: &List(NodeId), params: FunctionParam[]) {
    for &prm in params {
        if prm.is_slot {
            slots.push(self.node_of(prm.span))
        }
    }
}

fn own_is_slot(p: &OwnPass, decl: NodeId) bool {
    return own_list_has(&p.slots, decl)
}

// The slot parameter a place is reached through, when the place is a dereference of one: `slot.*`
// and nothing else names the value a `&move` parameter points at.
fn own_slot_root(self: &Checker, p: &OwnPass, e: &Expr) NodeId? {
    const inner = e.* match {
        Dereference(d) => d.operand
        _ => return null
    }
    const id = inner.* match {
        Identifier(x) => x
        _ => return null
    }
    const d = own_local_decl(self, self.node_of(id.span))
    if d.is_none() or !own_is_slot(p, d.unwrap()) {
        return null
    }
    return d
}

// One body's pass. Takes ownership of `lent` and `captured`.
fn own_run(
    self: &Checker,
    body: &BlockExpr,
    lent: move List(NodeId),
    captured: move List(NodeId),
    returns: bool,
    slots: move List(NodeId) = list(0),
) {
    // `slots` is moved into the pass below; its span is the body's, for the exit check.
    let p = OwnPass {
        moved = list(0),
        paths = list(0),
        defers = list(0),
        escaped = list(0),
        continued = list(0),
        scope = 0usize,
        loop_scope = 0usize,
        in_loop = false,
        diverged = false,
        report = true,
        firing = false,
        seen = set(),
        lent = move lent,
        captured = move captured,
        slots = move slots,
        borrowed = list(0),
        uncertain = list(0),
        taker = "",
    }
    own_block(self, &p, body, if returns { own_returning() } else { own_read() })
    if !p.diverged {
        own_check_slots_filled(self, &p, body.span)
    }
    own_deinit(p)
}

fn own_collect_lent(self: &Checker, lent: &List(NodeId), params: FunctionParam[]) {
    for &prm in params {
        if !prm.is_move and !prm.is_variadic {
            lent.push(self.node_of(prm.span))
        }
    }
}

// A lambda literal reads every name it captures where it is built. Its body is a body of its own:
// parameters by mode, captures as references - a capture of a name the enclosing body only reads
// stays read-only. Checked once, on the reporting walk, however often the literal is revisited.
fn own_lambda(self: &Checker, p: &OwnPass, lam: &LambdaExpr) {
    const info = self.results.lambdas.get_ref(self.node_of(lam.span))
    if info.is_none() {
        return
    }
    const captures = &info.unwrap().captures
    for &cap in captures {
        if own_has_moves(p, cap.decl) and own_claim(p, self.node_of(lam.body.span)) {
            own_report(
                self,
                lam.span,
                E_USE_AFTER_MOVE,
                $"`{cap.name}` was moved and cannot be captured",
            )
        }
    }
    if !own_claim(p, self.node_of(lam.span)) {
        return
    }
    let lent: List(NodeId) = list(captures.len)
    let captured: List(NodeId) = list(captures.len)
    own_collect_lent(self, &lent, lam.params)
    for &cap in captures {
        if own_is_lent(p, cap.decl) {
            lent.push(cap.decl)
        } else {
            captured.push(cap.decl)
        }
    }
    const ret = self.engine.resolve(info.unwrap().ret)
    own_run(self, lam.body, lent, captured, ret != TY_VOID and ret != TY_NEVER, list(0))
}

fn own_deinit(p: move OwnPass) {
    p.moved.deinit()
    p.paths.deinit()
    p.defers.deinit()
    p.escaped.deinit()
    p.continued.deinit()
    p.seen.deinit()
    p.lent.deinit()
    p.captured.deinit()
    p.slots.deinit()
    p.borrowed.deinit()
    p.uncertain.deinit()
}

fn own_is_lent(p: &OwnPass, decl: NodeId) bool {
    if own_list_has(&p.lent, decl) {
        return true
    }
    const b = own_borrowed(p, decl)
    return b.is_some() and b.unwrap().read_only
}

fn own_borrowed(p: &OwnPass, decl: NodeId) BorrowedRec? {
    for b in p.borrowed {
        if b.decl == decl {
            return Some(b)
        }
    }
    return null
}

fn own_is_captured(p: &OwnPass, decl: NodeId) bool {
    return own_list_has(&p.captured, decl)
}

fn own_list_has(xs: &List(NodeId), decl: NodeId) bool {
    for d in xs {
        if d == decl {
            return true
        }
    }
    return false
}

// ── the moved set ────────────────────────────────────────────────────

// Whether any part of the binding is moved, whole or a field.
fn own_has_moves(p: &OwnPass, decl: NodeId) bool {
    for &m in p.moved {
        if m.decl == decl {
            return true
        }
    }
    return false
}

fn own_mark(p: &OwnPass, decl: NodeId) {
    own_unmark(p, decl)
    p.moved.push(MovedRec { decl = decl, path = "" })
}

// Records a field moved out of `decl`. A move above it already covers it; moves below it are
// subsumed.
fn own_mark_field(self: &Checker, p: &OwnPass, decl: NodeId, path: String) {
    if own_moved_above(p, decl, path).is_some() {
        return
    }
    own_unmark_field(p, decl, path)
    let stored = from_view(path)
    p.moved.push(MovedRec { decl = decl, path = stored.view })
    p.paths.push(stored)
}

// Makes the whole binding live: every move recorded under it is gone. The `for` variable starts
// each iteration live.
fn own_fresh_var(p: &OwnPass, var_decl: NodeId?) {
    if var_decl.is_some() {
        own_unmark(p, var_decl.unwrap())
    }
}

// Drops the `for` variable from a carried state: it does not outlive the iteration that moved it.
fn own_drop_decl(state: &List(MovedRec), var_decl: NodeId?) {
    if var_decl.is_none() {
        return
    }
    const decl = var_decl.unwrap()
    let i = 0
    while i < state.len {
        if state[i].decl == decl {
            state[i] = state[state.len - 1]
            let _r = state.pop()
            continue
        }
        i = i + 1
    }
}

fn own_unmark(p: &OwnPass, decl: NodeId) {
    let i = 0
    while i < p.moved.len {
        if p.moved[i].decl == decl {
            p.moved[i] = p.moved[p.moved.len - 1]
            let _r = p.moved.pop()
            continue
        }
        i = i + 1
    }
}

// Makes the field at `path`, and everything below it, live again.
fn own_unmark_field(p: &OwnPass, decl: NodeId, path: String) {
    let i = 0
    while i < p.moved.len {
        if p.moved[i].decl == decl and path_within(p.moved[i].path, path) {
            p.moved[i] = p.moved[p.moved.len - 1]
            let _r = p.moved.pop()
            continue
        }
        i = i + 1
    }
}

// The recorded move at or above `path` - the whole binding, the field itself or an enclosing one.
fn own_moved_above(p: &OwnPass, decl: NodeId, path: String) String? {
    for &m in p.moved {
        if m.decl == decl and path_within(path, m.path) {
            return Some(m.path)
        }
    }
    return null
}

// The recorded move strictly below `path`, which leaves the place at `path` incomplete.
fn own_moved_below(p: &OwnPass, decl: NodeId, path: String) String? {
    for &m in p.moved {
        if m.decl == decl and m.path.len > path.len and path_within(m.path, path) {
            return Some(m.path)
        }
    }
    return null
}

// Whether field path `inner` is `outer` or lies below it. "" is the whole binding.
fn path_within(inner: String, outer: String) bool {
    if outer.len == 0 {
        return true
    }
    if !inner.starts_with(outer) {
        return false
    }
    return inner.len == outer.len or inner[outer.len] == '.'
}

// A pattern's bindings are declared where the pattern matches, so entering an arm makes them live
// however the state carried in from a back edge or an earlier arm has them.
fn own_unmark_pattern(self: &Checker, p: &OwnPass, pat: &Pattern) {
    pat.* match {
        Variable(v) => own_unmark(p, self.node_of(v.span))
        EnumVariant(ev) => {
            for i in 0..ev.payloads.len {
                own_unmark_pattern(self, p, &ev.payloads[i])
            }
        }
        Or(o) => {
            for i in 0..o.alternatives.len {
                own_unmark_pattern(self, p, &o.alternatives[i])
            }
        }
        Struct(st) => {
            for &f in st.fields {
                f.binding match {
                    Some(sub) => own_unmark_pattern(self, p, sub)
                    None => own_unmark(p, self.node_of(f.span))
                }
            }
        }
        Tuple(t) => {
            for i in 0..t.elements.len {
                own_unmark_pattern(self, p, &t.elements[i])
            }
        }
        _ => {}
    }
}

// A pattern binds in place, so a scrutinee the function does not own - a parameter without `move`,
// an element, storage behind a reference - lends its bindings. Null when the function owns it or it
// is a temporary.
fn own_is_place(e: &Expr) bool {
    return e.* match {
        Identifier(_) => true
        MemberAccess(_) => true
        Index(_) => true
        Dereference(_) => true
        _ => false
    }
}

fn own_unowned_scrutinee(self: &Checker, p: &OwnPass, e: &Expr) BorrowedRec? {
    if !own_is_place(e) or own_owned_base(self, p, e) {
        return null
    }
    const lent = own_lent_root(self, p, e)
    const root = lent ?? own_chain_root(self, e)
    const from = root match {
        Some(id) => id.name
        None => ""
    }
    return Some(BorrowedRec {
        decl = self.node_of(expr_span(e)),
        from = from,
        read_only = lent.is_some(),
    })
}

fn own_borrow_pattern(self: &Checker, p: &OwnPass, pat: &Pattern, from: BorrowedRec) {
    pat.* match {
        Variable(v) => p.borrowed.push(BorrowedRec {
            decl = self.node_of(v.span),
            from = from.from,
            read_only = from.read_only,
        })
        EnumVariant(ev) => {
            for &sub in ev.payloads {
                own_borrow_pattern(self, p, sub, from)
            }
        }
        Or(o) => {
            for &sub in o.alternatives {
                own_borrow_pattern(self, p, sub, from)
            }
        }
        Struct(st) => {
            for &f in st.fields {
                f.binding match {
                    Some(sub) => own_borrow_pattern(self, p, sub, from)
                    None => p.borrowed.push(BorrowedRec {
                        decl = self.node_of(f.span),
                        from = from.from,
                        read_only = from.read_only,
                    })
                }
            }
        }
        Tuple(t) => {
            for &sub in t.elements {
                own_borrow_pattern(self, p, sub, from)
            }
        }
        _ => {}
    }
}

fn own_snapshot(self: &Checker, src: &List(MovedRec)) List(MovedRec) {
    let out: List(MovedRec) = list(src.len)
    out.push_all(src.as_slice())
    return out
}

fn own_restore(dst: &List(MovedRec), src: &List(MovedRec)) {
    dst.clear()
    dst.push_all(src.as_slice())
}

// A value moved on any path into a merge is moved at the merge - no drop flags.
fn own_merge(dst: &List(MovedRec), src: &List(MovedRec)) {
    for i in 0..src.len {
        let found = false
        for j in 0..dst.len {
            if dst[j].decl == src[i].decl and dst[j].path == src[i].path {
                found = true
            }
        }
        if !found {
            dst.push(src[i])
        }
    }
}

// ── reporting ────────────────────────────────────────────────────────

// Whether this pass will emit a diagnostic at `node`, claiming it if so.
fn own_claim(p: &OwnPass, node: NodeId) bool {
    if !p.report or p.seen.contains(node) {
        return false
    }
    p.seen.add(node)
    return true
}

// A copy rejected inside a generic body belongs to the caller: the template is written once, and
// this instantiation is what made the type non-copyable. Reporting at the outermost open
// instantiation names a line in the file the author is editing rather than one in the stdlib.
fn own_report(self: &Checker, span: SourceSpan, code: String, msg: move OwnedString) {
    const at = if self.spec_call_spans.len > 0 { self.spec_call_spans[0] } else { span }
    push_diag_e(self, at, code, msg)
}

fn own_type(self: &Checker, span: SourceSpan) Ty? {
    return self.results.get_type(self.node_of(span))
}

// The declaration node a name reference resolves to, or null when the name is not a local.
fn own_local_decl(self: &Checker, node: NodeId) NodeId? {
    const t = self.results.resolved_targets.get(node)
    if t.is_none() {
        return null
    }
    return t.unwrap() match {
        RtLocal(d) => Some(d)
        _ => null
    }
}

fn own_is_copyable(self: &Checker, span: SourceSpan) bool {
    const t = own_type(self, span)
    return t match {
        Some(ty) => ty_copyable(self, self.engine.resolve(ty))
        None => true
    }
}

// ── copy and ownership sites ─────────────────────────────────────────

fn own_blame(self: &Checker, span: SourceSpan, sb: &StringBuilder) {
    const t = own_type(self, span)
    t match {
        Some(ty) => append_copy_blame(self, self.engine.resolve(ty), sb)
        None => {}
    }
}

fn own_is_ref(self: &Checker, span: SourceSpan) bool {
    const t = own_type(self, span)
    if t.is_none() {
        return false
    }
    return ty_node(self, self.engine.resolve(t.unwrap())) match {
        NRef(_) => true
        _ => false
    }
}

// A copy is reading an lvalue into a second location: the original keeps its storage and the result
// gets its own, so both end up responsible for one resource. Only the lvalue forms funnel here,
// which is why an rvalue needs no `move`.
fn own_copy_site(self: &Checker, p: &OwnPass, span: SourceSpan, name: String) {
    if !own_claim(p, self.node_of(span)) {
        return
    }
    let sb = string_builder(160)
    if name.len > 0 {
        sb.append($"`{name}` cannot be copied here - write `move {name}`")
    } else {
        sb.append("this value cannot be copied here - write `move` to transfer it")
    }
    own_blame(self, span, &sb)
    own_report(self, span, E_COPY_NEEDS_MOVE, sb.to_string())
}

// A parameter without `move` is read access (rule 3): writing, sharing, binding, returning or
// moving it needs a copy or ownership, which a non-copyable type does not give.
fn own_lent_error(self: &Checker, p: &OwnPass, id: &IdentifierExpr, what: String) {
    if !own_claim(p, self.node_of(id.span)) {
        return
    }
    const d = own_local_decl(self, self.node_of(id.span))
    const b = if d.is_some() { own_borrowed(p, d.unwrap()) } else { null }
    if b.is_some() {
        own_borrowed_error(self, p, id, b.unwrap(), what)
        return
    }
    let sb = string_builder(160)
    sb.append($"`{id.name}` is not owned here: {what}; declare `{id.name}: move ")
    own_type(self, id.span) match {
        Some(ty) => format_with_names(
            &self.engine.interner,
            self.engine.zonk(ty),
            &sb,
            Some(&self.nominals),
            Some(&self.tp_names),
        )
        None => {}
    }
    sb.append("` to own it")
    own_taker_note(p, &sb)
    own_report(self, id.span, E_NOT_OWNED, sb.to_string())
}

fn own_borrowed_error(
    self: &Checker,
    p: &OwnPass,
    id: &IdentifierExpr,
    b: BorrowedRec,
    what: String,
) {
    let sb = string_builder(160)
    if b.from.len > 0 {
        sb.append($"`{id.name}` names part of `{b.from}`, which is not owned here")
    } else {
        sb.append($"`{id.name}` names storage this function does not own")
    }
    sb.append($": {what}")
    own_taker_note(p, &sb)
    own_report(self, id.span, E_NOT_OWNED, sb.to_string())
}

// A capture refers to the enclosing body's binding, which keeps its value.
fn own_captured_error(self: &Checker, p: &OwnPass, id: &IdentifierExpr) {
    if !own_claim(p, self.node_of(id.span)) {
        return
    }
    let sb = string_builder(160)
    sb.append(
        $"`{id.name}` is captured by reference: the closure cannot take its value out of the enclosing binding",
    )
    own_taker_note(p, &sb)
    own_blame(self, id.span, &sb)
    own_report(self, id.span, E_NOT_OWNED, sb.to_string())
}

// Names the function value a lent value was handed to, so a callback that takes ownership reads as
// the cause when the error surfaces inside a combinator's body.
fn own_taker_note(p: &OwnPass, sb: &StringBuilder) {
    if p.taker.len > 0 {
        sb.append($"; `{p.taker}` takes ownership of its argument")
    }
}

// A non-copyable temporary where nothing takes ownership is never released (rule 8).
fn own_temporary(self: &Checker, p: &OwnPass, e: &Expr, slot: OwnSlot) {
    if own_needs_value(slot) or slot.owner {
        return
    }
    const temporary = e.* match {
        Call(_) => true
        Try(_) => true
        StructLit(_) => true
        ArrayLit(_) => true
        TupleLit(_) => true
        _ => false
    }
    const span = expr_span(e)
    if !temporary or own_is_copyable(self, span) or !own_claim(p, self.node_of(span)) {
        return
    }
    let sb = string_builder(160)
    sb.append("this value reaches no owner and is never released - bind it to a variable")
    own_blame(self, span, &sb)
    own_report(self, span, E_RVALUE_NO_OWNER, sb.to_string())
}

// ── expressions ──────────────────────────────────────────────────────

fn own_expr(self: &Checker, p: &OwnPass, e: &Expr, slot: OwnSlot) {
    own_temporary(self, p, e, slot)
    e.* match {
        Identifier(id) => own_ident(self, p, &id, slot)
        Move(m) => own_move(self, p, &m, slot)
        MemberAccess(ma) => {
            own_member_use(self, p, &ma)
            if !own_rvalue_name(self, self.node_of(ma.span)) {
                own_place_site(self, p, e, slot)
            }
        }
        Index(ix) => {
            own_expr(self, p, ix.receiver, own_read())
            own_expr(self, p, ix.index, own_read())
            own_place_site(self, p, e, slot)
        }
        Dereference(d) => {
            own_expr(self, p, d.operand, own_read())
            own_place_site(self, p, e, slot)
        }
        AddressOf(a) => {
            own_share(self, p, a.operand)
            own_expr(self, p, a.operand, own_read())
        }
        NullPropagation(np) => own_expr(self, p, np.receiver, own_read())
        Call(c) => own_call(self, p, &c)
        StructLit(sl) => own_struct_lit(self, p, &sl)
        ArrayLit(al) => own_array_lit(self, p, &al)
        TupleLit(tl) => {
            for &el in tl.elements {
                own_expr(self, p, el, own_value())
            }
        }
        Assignment(a) => own_assign(self, p, &a)
        Binary(b) => {
            own_expr(self, p, b.lhs, own_read())
            own_expr(self, p, b.rhs, own_read())
        }
        Unary(u) => own_expr(self, p, u.operand, own_read())
        Cast(c) => own_expr(self, p, c.operand, own_read())
        // `a ?? b` hands out `a`'s payload: a kept result consumes `a`, with no marker, as an
        // operand of a `move` parameter would be; a result only read leaves `a` in place.
        Coalesce(c) => {
            own_expr(self, p, c.lhs, if own_needs_value(slot) { own_consuming() } else { slot })
            own_expr(self, p, c.rhs, slot)
        }
        Try(t) => own_protocol(self, p, t.span, t.operand)
        Range(r) => {
            r.start match { Some(s) => own_expr(self, p, s, own_read()), None => {} }
            r.end match { Some(x) => own_expr(self, p, x, own_read()), None => {} }
        }
        InterpolatedString(istr) => own_interp(self, p, &istr)
        Lambda(lam) => own_lambda(self, p, &lam)
        Block(b) => own_block(self, p, &b, slot)
        If(ife) => own_if(self, p, &ife, slot)
        Match(m) => own_match(self, p, &m, slot)
        ContextBind(cb) => {
            for &a in cb.args {
                a.* match {
                    Positional(e) => own_expr(self, p, e, own_read())
                    Named(n) => own_expr(self, p, n.value, own_read())
                }
            }
            own_block(self, p, cb.body, slot)
        }
        _ => {}
    }
}

fn own_ident(self: &Checker, p: &OwnPass, id: &IdentifierExpr, slot: OwnSlot) {
    const node = self.node_of(id.span)
    const d = own_local_decl(self, node)
    if d.is_some() and own_has_moves(p, d.unwrap()) {
        own_moved_use(self, p, d.unwrap(), id.name, "", id.span)
        return
    }
    if !own_needs_value(slot) or own_rvalue_name(self, node) or own_is_copyable(self, id.span) {
        return
    }
    if d.is_some() and own_borrowed(p, d.unwrap()).is_some() {
        own_lent_error(self, p, id, "moving it out needs ownership of the matched value")
        return
    }
    if d.is_some() and own_is_lent(p, d.unwrap()) {
        own_lent_error(self, p, id, "a parameter without `move` can only be read")
        return
    }
    if d.is_some() and own_is_captured(p, d.unwrap()) {
        own_captured_error(self, p, id)
        return
    }
    const takes = slot.consumes or slot.returns
    if takes and d.is_some() {
        own_mark(p, d.unwrap())
        return
    }
    own_copy_site(self, p, id.span, id.name)
}

// Reports a use of the place `name.path` (`path` "" for the binding itself) when a move recorded on
// the binding reaches it: the place or an enclosing one was moved, or a field below it was moved
// out and left it incomplete.
fn own_moved_use(
    self: &Checker,
    p: &OwnPass,
    decl: NodeId,
    name: String,
    path: String,
    span: SourceSpan,
) {
    const node = self.node_of(span)
    const above = own_moved_above(p, decl, path)
    if above.is_some() {
        if own_claim(p, node) {
            const shown = place_text(name, path)
            defer shown.deinit()
            own_report(self, span, E_USE_AFTER_MOVE, $"`{shown.view}` was moved and cannot be used")
        }
        return
    }
    const below = own_moved_below(p, decl, path)
    if below.is_none() or !own_claim(p, node) {
        return
    }
    const shown = place_text(name, path)
    defer shown.deinit()
    const field = if path.len == 0 { below.unwrap() } else { below.unwrap()[path.len + 1..] }
    own_report(
        self,
        span,
        E_USE_AFTER_MOVE,
        $"`{shown.view}` is incomplete: field `{field}` was moved out - assign it before using `{shown.view}`",
    )
}

fn place_text(name: String, path: String) OwnedString {
    if path.len == 0 {
        return from_view(name)
    }
    return $"{name}.{path}"
}

// A field chain over a binding the function owns: its uses meet the field-level moved set. Any
// other member access reads its receiver as usual.
fn own_member_use(self: &Checker, p: &OwnPass, ma: &MemberAccessExpr) {
    const root = own_chain_root(self, ma.receiver)
    if root.is_none() {
        own_expr(self, p, ma.receiver, own_read())
        return
    }
    const id = root.unwrap()
    const d = own_local_decl(self, self.node_of(id.span))
    if d.is_none() or !own_has_moves(p, d.unwrap()) {
        return
    }
    const path = member_path(ma)
    defer path.deinit()
    own_moved_use(self, p, d.unwrap(), id.name, path.view, ma.span)
}

// The identifier a chain of field accesses starts from, when no step goes through a reference.
fn own_chain_root(self: &Checker, e: &Expr) IdentifierExpr? {
    if own_is_ref(self, expr_span(e)) {
        return null
    }
    return e.* match {
        Identifier(id) => Some(id)
        MemberAccess(inner) => own_chain_root(self, inner.receiver)
        _ => null
    }
}

// `a.b.c` below its root identifier: "b.c".
fn member_path(ma: &MemberAccessExpr) OwnedString {
    return ma.receiver.* match {
        MemberAccess(inner) => {
            const head = member_path(&inner)
            defer head.deinit()
            $"{head.view}.{ma.member}"
        }
        _ => from_view(ma.member)
    }
}

// A name whose value is built where it stands rather than read out of storage: a nullary variant
// constructor (`None`, `Color.Red`) and a function taken as a value. Nothing is duplicated when one
// is bound, passed or stored, so no `move` is owed - the same reason a call result owes none.
fn own_rvalue_name(self: &Checker, node: NodeId) bool {
    const t = self.results.resolved_targets.get(node)
    if t.is_none() {
        return false
    }
    return t.unwrap() match {
        RtEnumVariant(_, _) => true
        RtFunction(_) => true
        RtSpecialized(_) => true
        _ => false
    }
}

// A field, an element or a dereference used by value. Into a `move` parameter the value has to
// leave its place, under the same rule an explicit `move` of that place follows (`own_move`): a
// field leaves a base the function owns, and anything reached through a field of a type this module
// declares may leave too. Otherwise an element stays in its container and a pointee with its owner
// (E2125).
fn own_place_site(self: &Checker, p: &OwnPass, e: &Expr, slot: OwnSlot) {
    const span = expr_span(e)
    if !own_needs_value(slot) or own_is_copyable(self, span) {
        return
    }
    if !slot.consumes {
        own_copy_site(self, p, span, "")
        return
    }
    e.* match {
        MemberAccess(ma) => own_field_move(self, p, &ma, e)
        Index(_) => own_move_storage(
            self,
            p,
            e,
            "an element stays in its container - take it out with `pop`, `remove` or a drain",
        )
        _ => own_move_storage(self, p, e, "the value behind a reference stays with its owner")
    }
}

fn own_no_place(self: &Checker, p: &OwnPass, span: SourceSpan, why: String) {
    if !own_claim(p, self.node_of(span)) {
        return
    }
    let sb = string_builder(160)
    sb.append($"cannot take ownership of this value: {why}")
    own_taker_note(p, &sb)
    own_report(self, span, E_MOVE_NOT_LVALUE, sb.to_string())
}

// Moving a field out, spelled `move b.f` or handed to a `move` parameter, takes the rights of
// writing one (E2127) and a base the function owns: a value reached through a reference, or a
// parameter without `move`, keeps its fields. The exception is a place reached through an `owned`
// field of a type this module declares.
fn own_field_move(self: &Checker, p: &OwnPass, ma: &MemberAccessExpr, e: &Expr) {
    const node = self.node_of(ma.span)
    const elsewhere = field_owner_elsewhere(self, ma)
    if elsewhere.is_some() {
        const o = elsewhere.unwrap()
        if own_claim(p, node) {
            own_report(
                self,
                ma.span,
                E_PARTIAL_MOVE,
                $"cannot move field `{ma.member}` out of `{o.fqn}` from outside its defining module `{o.module}`",
            )
        }
        return
    }
    if own_owned_base(self, p, ma.receiver) {
        own_mark_member(self, p, ma)
        return
    }
    if own_through_owned_field(self, e) or !own_claim(p, node) {
        return
    }
    let sb = string_builder(160)
    sb.append(
        $"field `{ma.member}` cannot be moved out: its base is not owned here - a value reached through a reference, or a parameter without `move`, keeps its fields",
    )
    own_taker_note(p, &sb)
    own_report(self, ma.span, E_NOT_OWNED, sb.to_string())
}

// Records the field `ma` names as moved out of its root binding.
fn own_mark_member(self: &Checker, p: &OwnPass, ma: &MemberAccessExpr) {
    const root = own_chain_root(self, ma.receiver)
    if root.is_none() {
        return
    }
    const d = own_local_decl(self, self.node_of(root.unwrap().span))
    if d.is_none() {
        return
    }
    const path = member_path(ma)
    defer path.deinit()
    own_mark_field(self, p, d.unwrap(), path.view)
}

// Whether `e` names storage the function owns: a local, or a `move` parameter, and the fields of
// either, reached without passing through a reference.
fn own_owned_base(self: &Checker, p: &OwnPass, e: &Expr) bool {
    if own_is_ref(self, expr_span(e)) {
        return false
    }
    return e.* match {
        Identifier(id) => own_owned_decl(self, p, &id)
        MemberAccess(inner) => own_owned_base(self, p, inner.receiver)
        _ => false
    }
}

fn own_owned_decl(self: &Checker, p: &OwnPass, id: &IdentifierExpr) bool {
    const d = own_local_decl(self, self.node_of(id.span))
    return d.is_some() and !own_is_lent(p, d.unwrap()) and !own_is_captured(p, d.unwrap())
        and own_borrowed(p, d.unwrap()).is_none()
}

// The lent parameter at the root of a place reached without a reference, when its type is
// non-copyable: writing or sharing any part of it needs ownership.
fn own_lent_root(self: &Checker, p: &OwnPass, e: &Expr) IdentifierExpr? {
    return e.* match {
        Identifier(id) => own_lent_ident(self, p, &id)
        MemberAccess(ma) => own_lent_below(self, p, ma.receiver)
        Index(ix) => own_lent_below(self, p, ix.receiver)
        _ => null
    }
}

fn own_lent_below(self: &Checker, p: &OwnPass, receiver: &Expr) IdentifierExpr? {
    if own_is_ref(self, expr_span(receiver)) {
        return null
    }
    return own_lent_root(self, p, receiver)
}

fn own_lent_ident(self: &Checker, p: &OwnPass, id: &IdentifierExpr) IdentifierExpr? {
    const d = own_local_decl(self, self.node_of(id.span))
    const lent = d.is_some() and own_is_lent(p, d.unwrap())
    if !lent or own_is_copyable(self, id.span) {
        return null
    }
    return Some(id.*)
}

// `&place`, or a receiver adapted to `&T`: the callee may write through it.
fn own_share(self: &Checker, p: &OwnPass, e: &Expr) {
    own_lent_root(self, p, e) match {
        Some(id) => own_lent_error(self, p, &id, "sharing it needs ownership")
        None => {}
    }
}

// `move` marks the binding under it dead from here on, and a field of a binding the function owns
// moved out of it. A dereference, an index, and a field reached through a reference mark nothing: a
// reference carries no ownership. Argument position never reaches here: the checker refuses `move`
// there (E2129) and the call walks the operand as if unmarked.
fn own_move(self: &Checker, p: &OwnPass, m: &MoveExpr, slot: OwnSlot) {
    own_expr(self, p, m.operand, own_read())
    const takes = slot.value or slot.returns
    if !takes or own_is_copyable(self, expr_span(m.operand)) {
        own_warn_no_consume(self, p, m.span)
        return
    }
    m.operand.* match {
        Identifier(id) => own_move_binding(self, p, &id, m.span, slot)
        MemberAccess(ma) => own_field_move(self, p, &ma, m.operand)
        Index(_) => own_move_storage(
            self,
            p,
            m.operand,
            "an element stays in its container - take it out with `pop`, `remove` or a drain",
        )
        Dereference(_) => own_move_storage(
            self,
            p,
            m.operand,
            "the value behind a reference stays with its owner",
        )
        _ => {}
    }
}

// `move` through an element or a dereference: storage the checker cannot see the end of. The module
// that declares a type may take out of its `owned` fields - the storage it releases, and the
// scoped-mutability right that already lets it store into them - and nobody else may, or a lent
// reference would be a way to take ownership of what it points at (E2125).
fn own_move_storage(self: &Checker, p: &OwnPass, e: &Expr, why: String) {
    // `slot.*` of a `&move` parameter: the value leaves, and the slot is empty until it is refilled
    // (E2137 at the exit that finds it still empty).
    own_slot_root(self, p, e) match {
        Some(d) => {
            own_mark(p, d)
            return
        }
        None => {}
    }
    if own_through_owned_field(self, e) {
        return
    }
    own_no_place(self, p, expr_span(e), why)
}

// Whether the place `e` names is reached through an `owned` field of a type this module declares.
// Follows the base chain a container writes: `(self.entries + i).key`, `self.ptr[i]`, `(p + n).*`.
fn own_through_owned_field(self: &Checker, e: &Expr) bool {
    return e.* match {
        MemberAccess(ma) => own_owned_field_here(self, &ma)
            or own_through_owned_field(self, ma.receiver)
        Index(ix) => own_through_owned_field(self, ix.receiver)
        Dereference(d) => own_through_owned_field(self, d.operand)
        Binary(b) => own_through_owned_field(self, b.lhs) or own_through_owned_field(self, b.rhs)
        Cast(c) => own_through_owned_field(self, c.operand)
        Call(c) => own_raw_parts_of(&c) match {
            Some(ptr) => own_through_owned_field(self, ptr)
            None => false
        }
        _ => false
    }
}

// The pointer of a `slice_from_raw_parts(ptr, len)` call: the slice spans the storage `ptr`
// reaches.
fn own_raw_parts_of(c: &CallExpr) &Expr? {
    const named = c.callee.* match {
        Identifier(id) => id.name == "slice_from_raw_parts"
        _ => false
    }
    if !named or c.args.len != 2 {
        return null
    }
    return c.args[0] match {
        Positional(e) => Some(e)
        Named(_) => null
    }
}

// An `owned` field of a type declared in the module being checked: storage the type releases, which
// is what grants taking out of it through a reference. A plain field follows rule 3 instead.
fn own_owned_field_here(self: &Checker, ma: &MemberAccessExpr) bool {
    return field_owner_elsewhere(self, ma).is_none() and own_field_of_nominal(self, ma)
}

// Whether `ma` reads a declared `owned` field rather than a plain one, a method or an `op_deref`
// hop.
fn own_field_of_nominal(self: &Checker, ma: &MemberAccessExpr) bool {
    const recv = own_type(self, expr_span(ma.receiver))
    if recv.is_none() {
        return false
    }
    const nid = ty_node(self, peel_refs(self, recv.unwrap())) match {
        NNominal(nn) => Some(nn.id)
        _ => null
    }
    if nid.is_none() {
        return false
    }
    return self.nominals.get(nid.unwrap()).* match {
        NomStruct(sd) => struct_field_owned(&sd, ma.member)
        _ => false
    }
}

fn own_move_binding(
    self: &Checker,
    p: &OwnPass,
    id: &IdentifierExpr,
    move_span: SourceSpan,
    slot: OwnSlot,
) {
    const d = own_local_decl(self, self.node_of(id.span))
    if d.is_none() {
        return
    }
    if own_is_lent(p, d.unwrap()) {
        own_lent_error(self, p, id, "a parameter without `move` can only be read")
        return
    }
    if own_is_captured(p, d.unwrap()) {
        own_captured_error(self, p, id)
        return
    }
    own_mark(p, d.unwrap())
    if slot.returns {
        own_note_redundant(self, p, move_span, id.name)
    }
}

// `return move x`: a returned binding can only move. A note, not a warning - the marker is
// harmless.
fn own_note_redundant(self: &Checker, p: &OwnPass, span: SourceSpan, name: String) {
    if self.spec_depth > 0 or !own_claim(p, self.node_of(span)) {
        return
    }
    push_diag_i(
        self,
        span,
        I_REDUNDANT_MOVE,
        $"redundant `move`: returning `{name}` already moves it",
    )
}

// A `move` at a site that does not consume does nothing. It is a warning rather than an error so a
// `move` that outlives its type becoming copyable does not break the build.
//
// A generic body is only ever checked at an instantiation, so `move value` where `value: T` would
// be diagnosed against whatever `T` resolved to there; the ticket diagnoses it against the type as
// written, which is to say not at all.
fn own_warn_no_consume(self: &Checker, p: &OwnPass, span: SourceSpan) {
    if self.spec_depth > 0 {
        return
    }
    if !own_claim(p, self.node_of(span)) {
        return
    }
    push_diag_w(
        self,
        span,
        W_MOVE_NO_CONSUME,
        from_view("`move` here does not consume anything - the destination copies"),
    )
}

fn own_struct_lit(self: &Checker, p: &OwnPass, sl: &StructLiteralExpr) {
    for &fi in sl.fields {
        fi.value match {
            Some(v) => own_expr(self, p, v, own_value())
            None => {}
        }
    }
}

fn own_array_lit(self: &Checker, p: &OwnPass, al: &ArrayLiteralExpr) {
    al.kind match {
        Elements(es) => {
            for &el in es {
                own_expr(self, p, el, own_value())
            }
        }
        Repeat(r) => {
            own_expr(self, p, r.value, own_value())
            own_expr(self, p, r.count, own_read())
        }
    }
}

fn own_interp(self: &Checker, p: &OwnPass, interp: &InterpolatedStringExpr) {
    interp.target match {
        NewString(args) => {
            for &a in args {
                own_expr(self, p, a, own_read())
            }
        }
        IntoBuilder(b) => own_expr(self, p, b, own_read())
    }
    for &part in interp.parts {
        part.* match {
            Hole(h) => own_expr(self, p, h.expr, own_read())
            _ => {}
        }
    }
}

// ── calls ────────────────────────────────────────────────────────────

// How a call's arguments map onto its parameters' modes.
type OwnCallee = struct {
    // The declared function's parameters, for their `move` and `&`.
    decl: &DeclParams?
    // A function value's type, for its `move` bits.
    fn_ty: NFuncNode?
    // Parameters ahead of the first written argument: a UFCS receiver or an `op_call` value.
    shift: usize
    ufcs: bool
    // A variant constructor: its payloads are by-value destinations, like struct literal fields.
    payload: bool
    // The function value's name, for `OwnPass.taker`.
    name: String
    // `core.slice.move_to`: its source is a place it takes elements out of (RFC-034).
    relocates: bool
}

type OwnMode = struct {
    moves: bool
    is_ref: bool
    // `&move T`: the callee may take the value out of the slot (RFC-033). The caller keeps the
    // slot.
    takes: bool
}

// One argument of a call, for the move-and-lend check (rule 9).
type OwnUse = struct {
    expr: &Expr
    kind: u8
}

const USE_READ: u8 = 0
const USE_SHARE: u8 = 1
const USE_MOVE: u8 = 2

// Each argument flows into its parameter (RFC-033): a `move` parameter takes ownership, any other
// reads. The receiver follows the first parameter.
fn own_call(self: &Checker, p: &OwnPass, c: &CallExpr) {
    const callee = own_callee(self, c)
    let uses: List(OwnUse) = list(0)
    defer uses.deinit()
    c.callee.* match {
        MemberAccess(ma) => {
            if callee.ufcs {
                const r = own_strip_move(ma.receiver)
                uses.push(OwnUse { expr = r, kind = own_receiver(self, p, &callee, r) })
            } else {
                own_expr(self, p, c.callee, own_read())
            }
        }
        Identifier(_) => {}
        _ => own_expr(self, p, c.callee, own_read())
    }
    let i = callee.shift
    for &arg in c.args {
        arg.* match {
            Positional(e) => {
                own_arg(self, p, &callee, e, i, "", &uses)
                i = i + 1
            }
            Named(n) => own_arg(self, p, &callee, n.value, 0usize, n.name, &uses)
        }
    }
    // A shift is `move_to` over overlapping ranges of one buffer.
    if !callee.relocates {
        own_overlaps(self, p, &uses)
    }
    const unresolved = callee.decl.is_none() and callee.fn_ty.is_none() and !callee.payload
    if self.rigid_mode and unresolved {
        own_mark_uncertain(self, p, c)
    }
}

fn own_mark_uncertain(self: &Checker, p: &OwnPass, c: &CallExpr) {
    c.callee.* match {
        MemberAccess(ma) => own_uncertain_root(self, p, ma.receiver)
        _ => {}
    }
    for &arg in c.args {
        arg.* match {
            Positional(e) => own_uncertain_root(self, p, e)
            Named(n) => own_uncertain_root(self, p, n.value)
        }
    }
}

fn own_uncertain_root(self: &Checker, p: &OwnPass, e: &Expr) {
    own_chain_root(self, e) match {
        Some(id) => own_local_decl(self, self.node_of(id.span)) match {
            Some(d) => p.uncertain.push(d)
            None => {}
        }
        None => {}
    }
}

fn own_callee(self: &Checker, c: &CallExpr) OwnCallee {
    const node = self.node_of(c.span)
    let out = OwnCallee {
        decl = null,
        fn_ty = null,
        shift = 0usize,
        ufcs = false,
        payload = false,
        name = "",
        relocates = false,
    }
    const target = self.results.resolved_targets.get(node)
    const fid: u32? = target match {
        Some(t) => t match {
            RtFunction(f) => Some(f)
            RtSpecialized(sid) => Some(self.specs.get(sid).function_id)
            _ => null
        }
        None => null
    }
    if fid.is_some() {
        out.decl = self.fn_decl_params.get_ref(fid.unwrap())
        out.relocates = is_move_to(self, fid.unwrap())
        out.ufcs = c.callee.* match { MemberAccess(_) => true, _ => false }
        const callee_is_receiver = self.results.receiver_derefs.get_ref(node).is_some()
        if out.ufcs or callee_is_receiver {
            out.shift = 1usize
        }
        return out
    }
    out.payload = target match {
        Some(t) => t match { RtEnumVariant(_, _) => true, _ => false }
        None => false
    }
    const callee_ty = own_type(self, expr_span(c.callee))
    if out.payload or callee_ty.is_none() {
        return out
    }
    out.fn_ty = ty_node(self, self.engine.resolve(callee_ty.unwrap())) match {
        NFunc(f) => Some(f)
        _ => null
    }
    out.name = c.callee.* match {
        Identifier(id) => id.name
        MemberAccess(ma) => ma.member
        _ => ""
    }
    return out
}

fn is_move_to(self: &Checker, id: u32) bool {
    const overloads = self.functions.by_name.get_ref("move_to")
    if overloads.is_none() {
        return false
    }
    for &f in overloads.unwrap() {
        if f.id == id and f.module match { Some(m) => m == "core.slice", None => false } {
            return true
        }
    }
    return false
}

// `move_to`'s source: a non-copyable element leaves it, so it is held to the rule `move` is.
fn own_relocate(self: &Checker, p: &OwnPass, src: &Expr) {
    own_expr(self, p, src, own_read())
    if own_slice_elem_copyable(self, expr_span(src)) or own_through_owned_field(self, src) {
        return
    }
    own_no_place(
        self,
        p,
        expr_span(src),
        "`move_to` takes non-copyable elements only out of an `owned` field this module declares",
    )
}

fn own_slice_elem_copyable(self: &Checker, span: SourceSpan) bool {
    const t = own_type(self, span)
    if t.is_none() {
        return true
    }
    const elem = ty_node(self, peel_refs(self, t.unwrap())) match {
        NNominal(n) => if n.args.len == 1 { Some(self.engine.interner.child_at(
            n.args,
            0,
        )) } else { null }
        _ => null
    }
    return elem.is_none() or ty_copyable(self, elem.unwrap())
}

fn own_param_mode(self: &Checker, callee: &OwnCallee, idx: usize, name: String) OwnMode {
    let mode = OwnMode { moves = false, is_ref = false, takes = false }
    if callee.decl.is_some() {
        const decl = &callee.decl.unwrap().params
        const at = own_param_index(decl, idx, name)
        if at < decl.len {
            mode.moves = decl[at].is_move
            mode.is_ref = decl[at].type_expr.* match { Reference(_) => true, _ => false }
            mode.takes = decl[at].is_slot and mode.is_ref
        }
        return mode
    }
    if callee.fn_ty.is_some() {
        const f = callee.fn_ty.unwrap()
        if idx < f.params.len {
            mode.moves = moves_at(&f, idx)
            const pt = self.engine.resolve(self.engine.interner.child_at(f.params, idx))
            mode.is_ref = ty_node(self, pt) match { NRef(_) => true, _ => false }
        }
    }
    return mode
}

// The declared position of positional argument `idx`, or of the parameter called `name`; past the
// end when there is none.
fn own_param_index(decl: &List(FunctionParam), idx: usize, name: String) usize {
    if name.len == 0 {
        return idx
    }
    for i in 0..decl.len {
        if decl[i].name == name {
            return i
        }
    }
    return decl.len
}

// The receiver flows into the first parameter; returns how it reached it, for rule 9.
fn own_receiver(self: &Checker, p: &OwnPass, callee: &OwnCallee, r: &Expr) u8 {
    if callee.relocates {
        own_relocate(self, p, r)
        return USE_READ
    }
    const mode = own_param_mode(self, callee, 0usize, "")
    if mode.moves {
        own_take(self, p, callee, r)
        return USE_MOVE
    }
    const adapted = mode.is_ref and !own_is_ref(self, expr_span(r))
    if adapted {
        own_share(self, p, r)
    }
    own_expr(self, p, r, own_read())
    return if adapted { USE_SHARE } else { USE_READ }
}

// The operand of a form that desugars to a protocol call - `for x in e` to `e.iter()`, `e?` to
// `op_try(e)` - flows into that call's first parameter like any receiver. The pick is recorded on
// `node_span`; with none (a checker error already reported) the operand is read.
fn own_protocol(self: &Checker, p: &OwnPass, node_span: SourceSpan, operand: &Expr) {
    const op = self.results.resolved_ops.get(self.node_of(node_span))
    if op.is_none() {
        own_expr(self, p, operand, own_read())
        return
    }
    const callee = OwnCallee {
        decl = self.fn_decl_params.get_ref(op.unwrap().function_id),
        fn_ty = null,
        shift = 1usize,
        ufcs = true,
        payload = false,
        name = "",
        relocates = false,
    }
    const _kind = own_receiver(self, p, &callee, operand)
}

fn own_arg(
    self: &Checker,
    p: &OwnPass,
    callee: &OwnCallee,
    arg: &Expr,
    idx: usize,
    name: String,
    uses: &List(OwnUse),
) {
    if callee.payload {
        own_expr(self, p, arg, own_value())
        return
    }
    const e = own_strip_move(arg)
    const is_src = (name.len == 0 and idx == 0) or name == "src"
    if callee.relocates and is_src {
        own_relocate(self, p, e)
        uses.push(OwnUse { expr = e, kind = USE_READ })
        return
    }
    const mode = own_param_mode(self, callee, idx, name)
    if mode.moves {
        own_take(self, p, callee, e)
        uses.push(OwnUse { expr = e, kind = USE_MOVE })
        return
    }
    own_expr(self, p, e, own_read())
    const shares = e.* match { AddressOf(_) => true, _ => false }
    uses.push(OwnUse { expr = e, kind = if shares { USE_SHARE } else { USE_READ } })
}

fn own_take(self: &Checker, p: &OwnPass, callee: &OwnCallee, e: &Expr) {
    const was = p.taker
    p.taker = callee.name
    own_expr(self, p, e, own_consuming())
    p.taker = was
}

// The operand of a `move` the checker already refused in argument position (E2129).
fn own_strip_move(e: &Expr) &Expr {
    return e.* match {
        Move(m) => m.operand
        _ => e
    }
}

// Rule 9: a call that takes ownership of a place cannot also read or share it, nor may it share a
// place another argument reads, when the overlap holds owned state - the callee would release or
// grow what it is also reading. Two moves of one binding are liveness's (E2123).
fn own_overlaps(self: &Checker, p: &OwnPass, uses: &List(OwnUse)) {
    if uses.len < 2 {
        return
    }
    for i in 0..uses.len {
        for j in 0..uses.len {
            if own_pair_reported_from(&uses[i], &uses[j], i, j) {
                own_overlap(self, p, &uses[i], &uses[j])
            }
        }
    }
}

// Whether the pair (a, b) is checked from `a`'s side: `a` takes ownership or shares, and each
// unordered pair is checked once.
fn own_pair_reported_from(a: &OwnUse, b: &OwnUse, i: usize, j: usize) bool {
    if i == j or a.kind == USE_READ {
        return false
    }
    if a.kind == USE_MOVE {
        return b.kind != USE_MOVE
    }
    return b.kind == USE_READ or (b.kind == USE_SHARE and i < j)
}

fn own_overlap(self: &Checker, p: &OwnPass, a: &OwnUse, b: &OwnUse) {
    let ha: List(OwnHop) = list(2)
    defer ha.deinit()
    let hb: List(OwnHop) = list(2)
    defer hb.deinit()
    const ra = own_place(self, a.expr, &ha)
    const rb = own_place(self, b.expr, &hb)
    if ra.is_none() or rb.is_none() or ra.unwrap() != rb.unwrap() {
        return
    }
    const common = if ha.len < hb.len { ha.len } else { hb.len }
    for k in 0..common {
        if ha[k].field != hb[k].field or !own_same_step(&ha[k], &hb[k]) {
            return
        }
    }
    const a_longer = ha.len >= hb.len
    const longer = if a_longer { &ha } else { &hb }
    const longer_expr = own_place_expr(if a_longer { a.expr } else { b.expr })
    let owned = !own_is_copyable(self, expr_span(longer_expr))
    for k in common..longer.len {
        if longer[k].owned {
            owned = true
        }
    }
    const span = expr_span(a.expr)
    if !owned or !own_claim(p, self.node_of(span)) {
        return
    }
    const how = if a.kind == USE_MOVE { "takes ownership of" } else { "shares" }
    own_report(
        self,
        span,
        E_MOVE_AND_LEND,
        $"this call {how} a value another argument also reaches: the overlap holds owned state",
    )
}

// One step below a place's root binding. `field` is "" for an element.
type OwnHop = struct {
    field: String
    // The step lands in storage the value owns: an `owned` field, or an element of a container.
    owned: bool
    // An element step's index, for telling one element of a container from another.
    index: &Expr?
}

// The local binding a place starts from, with the steps below it pushed onto `hops` root first.
// Null for anything reached through a reference, which aliases rather than owns.
fn own_place(self: &Checker, e: &Expr, hops: &List(OwnHop)) NodeId? {
    return e.* match {
        Identifier(id) => own_place_root(self, &id)
        AddressOf(a) => own_place(self, a.operand, hops)
        MemberAccess(ma) => own_place_step(
            self,
            ma.receiver,
            hops,
            OwnHop { field = ma.member, owned = own_field_owned(self, &ma), index = null },
        )
        Index(ix) => own_place_step(
            self,
            ix.receiver,
            hops,
            OwnHop { field = "", owned = !own_is_array(self, ix.receiver), index = Some(ix.index) },
        )
        _ => null
    }
}

// Whether two steps land in the same storage. Field steps are compared by name, element steps by
// the index as written: `s[i]` and `s[i]` are one place, `s[j]` and `s[j - 1]` are two, and an
// index this cannot read is taken as a different one - which leaves aliasing where spec 3.6 leaves
// it, rather than refusing an exchange of two elements.
fn own_same_step(a: &OwnHop, b: &OwnHop) bool {
    if a.index.is_none() and b.index.is_none() {
        return true
    }
    if a.index.is_none() or b.index.is_none() {
        return false
    }
    return own_same_index(a.index.unwrap(), b.index.unwrap())
}

fn own_same_index(a: &Expr, b: &Expr) bool {
    return a.* match {
        Identifier(x) => b.* match {
            Identifier(y) => x.name == y.name
            _ => false
        }
        Lit(x) => b.* match {
            Lit(y) => literal_text(&x) == literal_text(&y) and literal_text(&x).len > 0
            _ => false
        }
        _ => false
    }
}

// An integer literal's text, "" for every other literal - enough to tell `xs[0]` from `xs[1]`.
fn literal_text(l: &LiteralExpr) String {
    return l.value match {
        Int(i) => i.text
        _ => ""
    }
}

fn own_place_root(self: &Checker, id: &IdentifierExpr) NodeId? {
    if own_is_ref(self, id.span) {
        return null
    }
    return own_local_decl(self, self.node_of(id.span))
}

fn own_place_step(self: &Checker, receiver: &Expr, hops: &List(OwnHop), hop: OwnHop) NodeId? {
    if own_is_ref(self, expr_span(receiver)) {
        return null
    }
    const root = own_place(self, receiver, hops)
    hops.push(hop)
    return root
}

fn own_place_expr(e: &Expr) &Expr {
    return e.* match {
        AddressOf(a) => a.operand
        _ => e
    }
}

fn own_is_array(self: &Checker, e: &Expr) bool {
    const t = own_type(self, expr_span(e))
    if t.is_none() {
        return false
    }
    return ty_node(self, self.engine.resolve(t.unwrap())) match {
        NArray(_) => true
        _ => false
    }
}

// Whether the field `ma` reads is declared `owned` on its struct.
fn own_field_owned(self: &Checker, ma: &MemberAccessExpr) bool {
    const recv = own_type(self, expr_span(ma.receiver))
    if recv.is_none() {
        return false
    }
    const nid = ty_node(self, self.engine.resolve(recv.unwrap())) match {
        NNominal(nn) => Some(nn.id)
        _ => null
    }
    if nid.is_none() {
        return false
    }
    return self.nominals.get(nid.unwrap()).* match {
        NomStruct(sd) => struct_field_owned(&sd, ma.member)
        _ => false
    }
}

fn struct_field_owned(sd: &StructDef, name: String) bool {
    for &f in sd.fields {
        if f.name == name {
            return f.owned
        }
    }
    return false
}

fn own_assign(self: &Checker, p: &OwnPass, a: &AssignmentExpr) {
    own_expr(self, p, a.rhs, own_value())
    own_lent_root(self, p, a.lhs) match {
        Some(id) => {
            own_lent_error(self, p, &id, "writing it needs a copy")
            return
        }
        None => {}
    }
    a.lhs.* match {
        Identifier(id) => own_assign_binding(self, p, &id, a.span)
        MemberAccess(ma) => own_assign_field(self, p, &ma, a.span)
        Dereference(_) => own_assign_deref(self, p, a.lhs)
        _ => own_expr(self, p, a.lhs, own_read())
    }
}

// `slot.* = value` puts a value back into a `&move` parameter, which is what the take obliges. Any
// other dereference target is an ordinary write through a reference.
fn own_assign_deref(self: &Checker, p: &OwnPass, lhs: &Expr) {
    own_slot_root(self, p, lhs) match {
        Some(d) => own_unmark(p, d)
        None => own_expr(self, p, lhs, own_read())
    }
}

// Assigning a field of a binding the function owns reinitializes it when it was moved out, and
// leaks the old value when it is live. A field reached through a reference is only written.
fn own_assign_field(self: &Checker, p: &OwnPass, ma: &MemberAccessExpr, span: SourceSpan) {
    const root = own_chain_root(self, ma.receiver)
    const d = root match {
        Some(id) => own_local_decl(self, self.node_of(id.span))
        None => null
    }
    if d.is_none() or !own_owned_base(self, p, ma.receiver) {
        own_expr(self, p, ma.receiver, own_read())
        return
    }
    const path = member_path(ma)
    defer path.deinit()
    const released = own_released(self, p, d.unwrap(), path.view, own_type(self, ma.span))
    own_unmark_field(p, d.unwrap(), path.view)
    if released or own_is_copyable(self, ma.span) or !own_claim(p, self.node_of(ma.span)) {
        return
    }
    const shown = place_text(root.unwrap().name, path.view)
    defer shown.deinit()
    let sb = string_builder(160)
    sb.append($"`{shown.view}` is live - assigning over it leaks the value it holds")
    own_blame(self, ma.span, &sb)
    own_report(self, span, E_ASSIGN_OVER_LIVE, sb.to_string())
}

// Whether nothing the place `path` holds is still owned there: the place was moved, or every
// non-copyable field below it was. A binding of uncertain liveness counts as released.
fn own_released(self: &Checker, p: &OwnPass, decl: NodeId, path: String, ty: Ty?) bool {
    if own_list_has(&p.uncertain, decl) {
        return true
    }
    if own_moved_above(p, decl, path).is_some() {
        return true
    }
    if ty.is_none() {
        return false
    }
    const t = self.engine.resolve(ty.unwrap())
    if ty_copyable(self, t) {
        return true
    }
    if own_moved_below(p, decl, path).is_none() {
        return false
    }
    const nid = ty_node(self, t) match {
        NNominal(nn) => Some(nn.id)
        _ => null
    }
    if nid.is_none() {
        return false
    }
    const sd = self.nominals.get(nid.unwrap()).* match {
        NomStruct(s) => Some(move s)
        _ => null
    }
    if sd.is_none() {
        return false
    }
    const __sd_v = sd.unwrap()
    for &f in __sd_v.fields {
        const sub = if path.len == 0 { from_view(f.name) } else { $"{path}.{f.name}" }
        defer sub.deinit()
        if !own_released(self, p, decl, sub.view, struct_field_lookup(self, t, f.name)) {
            return false
        }
    }
    return true
}

// Assignment over a live binding overwrites what it holds and leaks it; over a moved one it
// reinitializes.
fn own_assign_binding(self: &Checker, p: &OwnPass, id: &IdentifierExpr, span: SourceSpan) {
    const node = self.node_of(id.span)
    const d = own_local_decl(self, node)
    if d.is_none() {
        return
    }
    const dd = d.unwrap()
    if own_released(self, p, dd, "", own_type(self, id.span)) {
        own_unmark(p, dd)
        return
    }
    if own_is_copyable(self, id.span) {
        return
    }
    if !own_claim(p, node) {
        return
    }
    let sb = string_builder(160)
    sb.append($"`{id.name}` is live - assigning over it leaks the value it holds")
    own_blame(self, id.span, &sb)
    own_report(self, span, E_ASSIGN_OVER_LIVE, sb.to_string())
}

// ── control flow ─────────────────────────────────────────────────────

// A block opens a scope: the defers registered inside it fire at its end, on the path that falls
// off it. The other exits fire them where they leave.
fn own_block(self: &Checker, p: &OwnPass, blk: &BlockExpr, slot: OwnSlot) {
    p.scope = p.scope + 1
    const here = p.scope
    for &st in blk.stmts {
        if p.diverged {
            break
        }
        own_stmt(self, p, st)
    }
    if !p.diverged {
        blk.trailing match {
            Some(e) => own_expr(self, p, e, slot)
            None => {}
        }
    }
    if !p.diverged {
        own_fire_defers(self, p, here)
    }
    own_drop_defers(p, here)
    p.scope = p.scope - 1
}

// Defers fire LIFO, so the last registered runs first and the earlier ones see its effects. The
// body is checked where it RUNS, which is why a `return` that moves what a defer touches leaves the
// defer holding a moved binding.
fn own_fire_defers(self: &Checker, p: &OwnPass, from_scope: usize) {
    if p.firing {
        return
    }
    p.firing = true
    let i = p.defers.len
    while i > 0 {
        i = i - 1
        if p.defers[i].scope >= from_scope {
            own_expr(self, p, p.defers[i].expr, own_read())
        }
    }
    p.firing = false
}

fn own_drop_defers(p: &OwnPass, scope: usize) {
    while p.defers.len > 0 and p.defers[p.defers.len - 1].scope >= scope {
        let _d = p.defers.pop()
    }
}

fn own_stmt(self: &Checker, p: &OwnPass, st: &Stmt) {
    st.* match {
        Let(ls) => own_let(self, p, &ls)
        Expression(es) => own_expr(self, p, es.expr, own_read())
        Return(rs) => own_return(self, p, &rs)
        Defer(ds) => p.defers.push(DeferRec { expr = ds.expr, scope = p.scope })
        Break(_) => own_escape(self, p, true)
        Continue(_) => own_escape(self, p, false)
        For(fs) => {
            // A temporary iterable is the loop's own once `record_iter_release` gave it a release.
            const loop_owned = self.results.resolved_ops.get(self.node_of(fs.var_span)).is_some()
                and !own_is_place(fs.iterable)
            if loop_owned {
                own_expr(self, p, fs.iterable, own_owning())
            } else {
                own_protocol(self, p, fs.body.span, fs.iterable)
            }
            own_loop(self, p, fs.body, Some(self.node_of(fs.var_span)))
        }
        While(ws) => {
            own_expr(self, p, ws.condition, own_read())
            own_loop(self, p, ws.body)
        }
        Loop(ls) => own_loop(self, p, ls.body)
        IfDirective(ifd) => own_if_directive(self, p, &ifd)
    }
}

fn own_let(self: &Checker, p: &OwnPass, ls: &LetStmt) {
    ls.init match {
        Some(e) => own_expr(self, p, e, own_value())
        None => {}
    }
    // The declaration makes the binding live again, which is what lets a `let` inside a loop body
    // survive the state the back edge carries in.
    own_unmark(p, self.node_of(ls.name_span))
}

// The value is evaluated first, then the active defers fire, then control transfers (spec 4.1).
// Every `&move` slot the body took from has to hold a value again at this exit.
fn own_check_slots_filled(self: &Checker, p: &OwnPass, span: SourceSpan) {
    for d in p.slots {
        if !own_has_moves(p, d) {
            continue
        }
        if !own_claim(p, self.node_of(span)) {
            return
        }
        push_diag_e(
            self,
            span,
            E_SLOT_NOT_REFILLED,
            from_view(
                "a `&move` slot is left empty: the value was taken out and none put back - assign through it before returning",
            ),
        )
        return
    }
}

fn own_return(self: &Checker, p: &OwnPass, rs: &ReturnStmt) {
    rs.value match {
        Some(e) => own_expr(self, p, e, own_returning())
        None => {}
    }
    own_fire_defers(self, p, 1usize)
    own_check_slots_filled(self, p, rs.span)
    p.diverged = true
}

// `break` and `continue` unwind the block's defers on their way out, and carry the state they leave
// with - to the loop's exit and to its next iteration respectively.
fn own_escape(self: &Checker, p: &OwnPass, is_break: bool) {
    if p.in_loop {
        own_fire_defers(self, p, p.loop_scope)
        if is_break {
            own_merge(&p.escaped, &p.moved)
        } else {
            own_merge(&p.continued, &p.moved)
        }
    }
    p.diverged = true
}

// The body runs an unknown number of times, so whatever it moves is moved on entry to the next
// iteration. The first pass is silent and only settles what the back edge carries; the second
// reports from that, which is a superset of the entry state, so a first-iteration error is reported
// too. Paths that left through `break` do not feed the back edge - they feed the exit. `var_decl`
// is a `for` variable: it is bound anew on every iteration, so a body that moves it leaves nothing
// moved for the next one, nor on the way out.
fn own_loop(self: &Checker, p: &OwnPass, body: &BlockExpr, var_decl: NodeId? = null) {
    const was_in = p.in_loop
    const was_scope = p.loop_scope
    const was_div = p.diverged
    let outer_escaped = own_snapshot(self, &p.escaped)
    defer outer_escaped.deinit()
    let outer_continued = own_snapshot(self, &p.continued)
    defer outer_continued.deinit()
    let entry = own_snapshot(self, &p.moved)
    defer entry.deinit()

    p.in_loop = true
    p.loop_scope = p.scope + 1
    p.escaped.clear()
    p.continued.clear()

    const was_report = p.report
    p.report = false
    p.diverged = false
    own_fresh_var(p, var_decl)
    own_block(self, p, body, own_read())
    let back = own_snapshot(self, &entry)
    defer back.deinit()
    if !p.diverged {
        own_merge(&back, &p.moved)
    }
    own_merge(&back, &p.continued)
    own_drop_decl(&back, var_decl)

    p.report = was_report
    p.escaped.clear()
    p.continued.clear()
    own_restore(&p.moved, &back)
    p.diverged = false
    own_fresh_var(p, var_decl)
    own_block(self, p, body, own_read())

    let exit = own_snapshot(self, &entry)
    defer exit.deinit()
    own_merge(&exit, &p.escaped)
    if !p.diverged {
        own_merge(&exit, &p.moved)
    }
    own_drop_decl(&exit, var_decl)
    own_restore(&p.moved, &exit)

    own_restore(&p.escaped, &outer_escaped)
    own_restore(&p.continued, &outer_continued)
    p.in_loop = was_in
    p.loop_scope = was_scope
    p.diverged = was_div
}

fn own_if(self: &Checker, p: &OwnPass, ife: &IfExpr, slot: OwnSlot) {
    own_expr(self, p, ife.condition, own_read())
    let entry = own_snapshot(self, &p.moved)
    defer entry.deinit()

    own_block(self, p, ife.then_branch, slot)
    let taken = own_snapshot(self, &p.moved)
    defer taken.deinit()
    const then_div = p.diverged

    own_restore(&p.moved, &entry)
    p.diverged = false
    ife.else_branch match {
        NoElse => {}
        Block(b) => own_block(self, p, b, slot)
        If(nested) => own_if(self, p, nested, slot)
    }
    const else_div = p.diverged

    // Only a branch that reaches the merge contributes to it.
    if !then_div {
        if else_div {
            own_restore(&p.moved, &taken)
        } else {
            own_merge(&p.moved, &taken)
        }
    }
    p.diverged = then_div and else_div
}

fn own_match(self: &Checker, p: &OwnPass, m: &MatchExpr, slot: OwnSlot) {
    own_expr(self, p, m.scrutinee, own_owning())
    const from = own_unowned_scrutinee(self, p, m.scrutinee)
    let entry = own_snapshot(self, &p.moved)
    defer entry.deinit()
    // Seeded empty, not from `entry`: an arm that reinitializes a moved binding leaves it live, and
    // starting from the entry state would carry the move past every arm that undid it.
    let merged: List(MovedRec) = list(entry.len)
    defer merged.deinit()

    let reached = false
    for &arm in m.arms {
        own_restore(&p.moved, &entry)
        own_unmark_pattern(self, p, arm.pattern)
        if from.is_some() {
            own_borrow_pattern(self, p, arm.pattern, from.unwrap())
        }
        p.diverged = false
        arm.guard match {
            Some(g) => own_expr(self, p, g, own_read())
            None => {}
        }
        own_expr(self, p, arm.body, slot)
        if p.diverged {
            continue
        }
        reached = true
        own_merge(&merged, &p.moved)
    }
    if reached {
        own_restore(&p.moved, &merged)
    } else {
        own_restore(&p.moved, &entry)
    }
    p.diverged = m.arms.len > 0 and !reached
}

// Only the active branch is checked, so only the active branch has types to check against.
fn own_if_directive(self: &Checker, p: &OwnPass, ifd: &IfDirectiveStmt) {
    directive_outcome(self, ifd) match {
        Active(active) => {
            const stmts = if active { ifd.then_stmts } else { ifd.else_stmts }
            for i in 0..stmts.len {
                if p.diverged {
                    return
                }
                own_stmt(self, p, &stmts[i])
            }
        }
        _ => {}
    }
}

pub fn check_all(
    self: &Checker,
    modules: &List(Module),
    paths: &List(String),
    sources: &List(OwnedString),
    file_paths: &List(OwnedString),
    generators: &TemplateState,
    order: &List(usize)? = null,
    recollect: &List(bool)? = null,
    demanded: &List(bool)? = null,
) TypeCheckResult {
    let seq = visit_sequence(self, modules.len, order)
    defer seq.deinit()
    self.nominals.clear_solved()
    // A new demand generation for the carried specialization registry: entries this demand never
    // touches are swept at the end (RFC-022 5e).
    self.specs.begin_gen()
    // Wire the import graph before any name resolution runs.
    const visibility_start = monotonic_ns()
    build_visibility(self, modules, paths)
    const visibility_ns = elapsed_ns(visibility_start)
    const collect_start = monotonic_ns()
    self.saw_new_name = false
    self.bounds_changed = false
    self.defaults_changed = false
    self.functions.reset_changed()

    // Phase 1: every module's type names are registered before any body resolves, so a struct field
    // or enum payload can name a type from another module regardless of the order modules are
    // checked in.
    //
    // A module the caller kept is already registered from the demand that last collected it. The
    // rest are retired before any of them registers, so a name on its way out is gone from the
    // registry by the time the module declaring it again reaches the duplicate check.
    let retiring: Set(String) = set()
    for i in seq {
        if !needs_collect(recollect, i) {
            continue
        }
        retiring.add(paths[i])
    }
    // What the retiring modules' aliases said before eviction - compared after collection to tell
    // an edit that touched an alias from one that did not, since a carried body baked its aliases
    // in expanded form. The nominal-definition and constant fingerprints serve the body caches the
    // same way (5d): taken before retirement frees the bodies, compared once the re-run passes have
    // re-registered.
    let old_aliases = snapshot_aliases(self, &retiring)
    let old_defs = snapshot_nominal_defs(self, &retiring)
    let old_consts = snapshot_types(&self.constants, &retiring, fn(t) { t })
    let old_ctx = snapshot_types(&self.ctx_fields, &retiring, fn(f) { f.ty })
    for i in seq {
        if needs_collect(recollect, i) {
            self.aliases.evict_module(paths[i])
        }
    }
    retire_names(self, &retiring)
    for i in seq {
        if !needs_collect(recollect, i) {
            replay_nominal_diags(self, paths[i], true)
            continue
        }
        const diags_from = self.diagnostics.len
        collect_nominal_names(self, &modules[i], paths[i])
        stash_nominal_diags(self, paths[i], diags_from, true)
    }
    const aliases_changed = aliases_differ(self, &old_aliases, &retiring)
    old_aliases.deinit()
    const collect_ns = elapsed_ns(collect_start)
    // Phase 1.5: source-generator expansion (RFC-021 §2) - generated
    // declarations are appended to their origin modules and collected, before any body resolves.
    // Their registrations reclaim the ids the previous expansion held, through the same `recycled`
    // map as declared names - origins with generated declarations are always re-collected.
    const templates_start = monotonic_ns()
    expand_templates(self, generators, modules, paths, sources, file_paths)
    const templates_ns = elapsed_ns(templates_start)
    // Whether the carried nominal bodies still say what this demand's sources would resolve: no
    // declared or generated name added (`saw_new_name`), none removed (an unclaimed retirement),
    // and no alias changed underneath a field that expanded it. Any of those and every body
    // resolves from source, as a cold check would.
    const bodies_carry = recollect.is_some() and !self.saw_new_name and !aliases_changed
        and !self.bounds_changed and !removed_names(self)
    const nominals_start = monotonic_ns()
    for i in seq {
        if bodies_carry and !needs_collect(recollect, i) {
            replay_nominal_diags(self, paths[i], false)
            burn_type_param_vars(self, &modules[i], paths[i])
            continue
        }
        const diags_from = self.diagnostics.len
        const vars_from = self.engine.var_counter
        self.ref_log.clear()
        self.ref_logging = true
        resolve_nominal_bodies(self, &modules[i], paths[i])
        self.ref_logging = false
        stash_nominal_diags(self, paths[i], diags_from, false)
        stash_resolve_burn(
            self,
            paths[i],
            self.engine.var_counter - vars_from,
            type_param_count(&modules[i]),
        )
    }
    const nominals_ns = elapsed_ns(nominals_start)
    // Whether re-resolution changed what any retiring nominal says. Added and removed names are
    // already covered by `bodies_carry`; this catches a definition edited in place.
    const noms_changed = nominal_defs_differ(self, &old_defs)
    old_defs.deinit()
    // Phase 2: signatures. Carried like nominal bodies (5c): a module the demand did not re-parse
    // skips the pass - its schemes, templates and constant types already sit in the carried
    // registries, and the rest of what the pass records replays from its cache. A module that
    // re-runs has its registry entries retired first, so its declarations reclaim their slots and
    // ids; retirements left unclaimed afterwards are removed declarations and are purged.
    // Retirement is per module and inline: a module's registrations only ever collide with its own
    // old entries (constants are FQN-scoped, E2103 is same-module), so nothing needs the whole set
    // retired up front.
    //
    // The skip decision is made at the module's turn because it reads the variable counter: a
    // carried handle (an unannotated constant's variable, a cached fact's leftover) is an ABSOLUTE
    // id, so it is only right while the module's burn starts where its pass once started. An edit
    // that changes an earlier module's signature-tier variable count shifts every later position;
    // the affected modules re-run once and their caches re-anchor.
    const signatures_start = monotonic_ns()
    const fns_before = self.functions.next_id
    self.engine.set_nominal_registry(&self.nominals)
    // Context fields first, every module every demand: a signature's default value may read one
    // declared further down or in a module checked later. A field re-registers at the id it held.
    for i in seq {
        self.ctx_fields.evict_module(paths[i])
    }
    for i in seq {
        register_context_fields(self, &modules[i], paths[i])
    }
    for i in seq {
        const skip = bodies_carry and !needs_collect(recollect, i)
            and sig_cache_ok(self, paths[i], self.engine.var_counter)
        if skip {
            replay_signature_cache(self, paths[i])
            continue
        }
        // A first demand has nothing carried to retire, and the scans are per module - skip them
        // wholesale on a cold check.
        if recollect.is_some() {
            self.functions.retire_module(paths[i])
            self.constants.evict_module(paths[i])
        }
        run_signature_pass(self, &modules[i], paths[i], sources)
    }
    let dead_fns = self.functions.purge_retired()
    for id in dead_fns {
        self.templates.remove(id) match {
            Some(t) => t.tps.deinit()
            None => {}
        }
        const _p = self.fn_decl_params.remove(id)
        const _d = self.fn_deprecations.remove(id)
    }
    const removed_fns = dead_fns.len > 0
    dead_fns.deinit()
    const signatures_ns = elapsed_ns(signatures_start)
    // Whether the signature phase re-registered anything differently: a reclaim that overwrote a
    // scheme, a function added (a fresh id) or removed (a purge), a constant added, removed or
    // re-typed, or a default value whose source text changed. Any of them and the carried body
    // slots are stale - resolution against the registries can now answer differently.
    const sigs_changed = self.functions.changed or self.functions.next_id != fns_before
        or removed_fns or self.defaults_changed
        or types_differ(&self.constants, &old_consts, &retiring, fn(t) { t })
        or types_differ(&self.ctx_fields, &old_ctx, &retiring, fn(f) { f.ty })
    old_consts.deinit()
    old_ctx.deinit()
    // A carried specialization of a re-parsed module's template holds a stale declaration AST, and
    // the body may have changed without the scheme changing - a demand for it re-instantiates in
    // place instead of replaying.
    mark_stale_specs(self, &retiring)
    retiring.deinit()
    // Phase 2.5: constant initializers, before any body can observe an unpinned const (see
    // `check_module_constants`).
    const constants_start = monotonic_ns()
    // Every signature is registered: a bounded type written from here on can be checked where it is
    // written (RFC-036).
    self.check_apps = true
    self.assoc_defs = any_assoc_defs(self)
    for i in seq {
        check_module_constants(self, &modules[i], paths[i])
    }
    const constants_ns = elapsed_ns(constants_start)
    // Phase 3: bodies, one module slot at a time. A slot is the module's bodies followed by the
    // settlement passes over what those bodies parked: anonymous literals (their field pins can be
    // what makes a generic pick concrete), overloaded names in value position, the specialization
    // drain, the calls whose overload an open type would have decided, a second drain for what
    // their resolution committed, and the literal sweep over what the slot minted. A slot ends
    // sealed - parked work its settlement could not resolve is abandoned, not handed to the next
    // module's slot.
    //
    // Settlement per slot is sound because bodies never share inference variables: a body's
    // variables entangle only with its own parked work and the instantiations its own picks force.
    // Module-level constants are the one cross-body channel, and phase 2.5 pins them before any
    // slot runs - `any_open_constant` guards the one case it cannot. The slot order is demand
    // order, so everything settlement assigns in encounter order - specialization ids, closure
    // environments, synthesized nodes - is decided per module, in module order. That is what lets a
    // module the demand did not re-parse REPLAY its slot from the body cache (5d), under the
    // carried-tier validity conditions plus the signature-tier fingerprints.
    const slots_carry = bodies_carry and !sigs_changed and !noms_changed
        and !any_open_constant(self)
    // A global trigger invalidates every carried specialization at once - they resolved against
    // registries that no longer say the same thing. Numbering restarts at zero, exactly a cold
    // check's.
    if !slots_carry {
        self.specs.reset()
    }
    const preamble_lits = self.pending_literals.len
    let bodies_ns = 0u64
    let specialize_ns = 0u64
    for i in seq {
        // Lazy demand (RFC-022 §6): a module outside the demand set has no body slot at all - its
        // bodies are never checked, produce no node types and no diagnostics. Everything before
        // phase 3 still ran for it: type names resolve program-wide, and its signatures and
        // constants are what a demanded body resolves calls against.
        if !is_demanded(demanded, i) {
            continue
        }
        const replay = slots_carry and !needs_collect(recollect, i)
            and body_cache_ok(self, paths[i])
        const t = if replay {
            replay_body_slot(self, paths[i])
        } else {
            run_body_slot(self, &modules[i], paths[i])
        }
        bodies_ns = bodies_ns + t.bodies_ns
        specialize_ns = specialize_ns + t.settle_ns
    }
    // Phase 3.6: the literals minted before any slot - signature defaults and constant
    // initializers. Validated after every slot because a body can be what pins an unannotated
    // constant's variable. This is all that remains of the program-wide literal sweep: every other
    // literal is swept and retired by its own slot, and the preamble re-parks per demand because
    // the constants phase is eager.
    const validate_start = monotonic_ns()
    validate_literals(self, 0, preamble_lits)
    specialize_ns = specialize_ns + elapsed_ns(validate_start)
    self.check_apps = false
    // Carried specializations nothing demanded this time are gone - a call site an edit removed
    // keeps no entry alive.
    self.specs.sweep()

    // RFC-014: settle the lambda/closure tables (the overlay-scoped lambda tables of instantiations
    // were zonked inside `instantiate`).
    const zonk_start = monotonic_ns()
    zonk_lambda_table(self)
    zonk_closures(self)
    // A nested instantiation can finish before its CALLER's body pins a type argument it inherited
    // (`list(0)` inside `to_list`, whose `$T` the enclosing `for item in it` settles afterwards).
    // Its own end-of-`instantiate` re-key ran too early, so each stored signature is zonked once
    // more here, now that inference is over - this is what the reference gets for free by mangling
    // at codegen. Scoped to the entries this demand instantiated; carried ones are final already.
    zonk_specializations(self)

    // Zonk every node-type entry so the result is final. Interned on the way (RFC-024): equal
    // shapes share one canonical tree. Presized: the zonked table holds exactly one entry per
    // source entry.
    let zonked: Dict(NodeId, Ty) = dict(self.results.node_types.len())
    for entry in self.results.node_types {
        zonked.set(entry.key, self.engine.zonk(entry.value))
    }
    solve_all_instances(self, &zonked)
    self.assoc_defs = false
    const zonk_ns = elapsed_ns(zonk_start)

    // Now that every type is final, fill this demand's signature captures (RFC-022 5c) and body
    // captures (5d) - the cached facts must hold the zonked types a skipped pass replays.
    harvest_sig_caches(self, &zonked)
    harvest_body_caches(self, &zonked)
    harvest_spec_caches(self)

    let out_context_fields = assemble_context(self)

    // Move the registries and result tables into the snapshot, then replace each moved-from field
    // with a fresh empty container so the caller's later `checker.deinit()` doesn't double-free
    // them.
    let out_resolved_ops = self.results.take_resolved_ops()
    let out_resolved_targets = self.results.take_resolved_targets()
    let out_instantiated_types = self.results.take_instantiated_types()
    let out_specializations = replace(&self.specs, specialization_registry())
    let out_desugars = self.results.take_desugars()
    let out_synth_strings = self.results.take_synth_strings()
    let out_default_args = self.results.take_default_args()
    let out_arg_lists = self.results.take_arg_lists()
    let out_receiver_derefs = self.results.take_receiver_derefs()
    let out_arg_derefs = self.results.take_arg_derefs()
    let out_receiver_adapts = self.results.take_receiver_adapts()
    // The snapshot takes the original; the checker keeps a deep copy (see below).
    const kept_nominals = self.nominals.carried_copy()
    let out_nominals = replace(&self.nominals, kept_nominals)
    const kept_functions = self.functions.carried_copy()
    let out_functions = replace(&self.functions, kept_functions)
    let out_lambdas = self.results.take_lambdas()
    let out_spans = self.results.take_spans()
    let out_closures = replace(&self.closures, dict())
    // The snapshot's tables share the interner's canonical storage, so the interner travels with
    // them; the next demand starts one afresh.
    let out_interner = self.engine.take_interner()

    // Owned copies, so the snapshot names the file of any span it holds without the caller's path
    // list. An empty `file_paths` leaves `path_of` reporting every file as unknown.
    let out_paths: List(OwnedString) = list(file_paths.len)
    for &fp in file_paths {
        out_paths.push(from_view(fp.view))
    }

    self.results.reset_side_tables()
    // What the next demand starts from: every definition at the id it holds, bodies included - the
    // declared and generated names, the anonymous records the intern map still cites, the closure
    // environments the next `begin_demand` retires. The snapshot keeps the original; the checker
    // keeps the deep copy taken above, whose handles the carried type table resolves. Whatever
    // retirement went unclaimed names a definition this demand's sources no longer declare; the
    // next demand starts its own ledger - seeded with the closure environments, which every body
    // pass rebuilds: their carried definitions are retired now, remembered against their
    // synthesized FQNs, so the next demand's identically-ordered lambdas reclaim these ids and mint
    // what a cold check would.
    self.recycled.clear()
    retire_closures(self, &out_closures)

    return TypeCheckResult {
        node_types = move zonked,
        interner = move out_interner,
        resolved_ops = move out_resolved_ops,
        resolved_targets = move out_resolved_targets,
        instantiated_types = move out_instantiated_types,
        specializations = move out_specializations,
        desugars = move out_desugars,
        synth_strings = move out_synth_strings,
        default_args = move out_default_args,
        arg_lists = move out_arg_lists,
        receiver_derefs = move out_receiver_derefs,
        receiver_adapts = move out_receiver_adapts,
        arg_derefs = move out_arg_derefs,
        nominals = move out_nominals,
        functions = move out_functions,
        lambdas = move out_lambdas,
        closures = move out_closures,
        spans = move out_spans,
        file_paths = move out_paths,
        context_fields = move out_context_fields,
        phases = CheckPhases {
            visibility_ns = visibility_ns,
            collect_ns = collect_ns,
            templates_ns = templates_ns,
            nominals_ns = nominals_ns,
            signatures_ns = signatures_ns,
            constants_ns = constants_ns,
            bodies_ns = bodies_ns,
            specialize_ns = specialize_ns,
            zonk_ns = zonk_ns,
        },
    }
}

// Whether module `i`'s bodies are in this demand's set. Same no-list-means-every-module rule as
// `needs_collect`, so a total demand and a first check behave alike.
fn is_demanded(demanded: &List(bool)?, i: usize) bool {
    return needs_collect(demanded, i)
}

// Whether module `i`'s names come from its source this demand. No list means every module, so a
// first check collects everything.
fn needs_collect(recollect: &List(bool)?, i: usize) bool {
    if recollect.is_none() {
        return true
    }
    const flags = recollect.unwrap()
    if i >= flags.len {
        return true
    }
    return flags[i]
}

// Take the closure-environment definitions out of the carried registry, each remembered against its
// synthesized FQN so the next demand's body pass re-registers it at the id it holds. The FQN views
// point into the carried registry's buffers, which eviction leaves in place.
fn retire_closures(self: &Checker, closures: &Dict(NominalId, ClosureSig)) {
    for e in closures {
        const found = self.nominals.find(e.key)
        if found.is_none() {
            continue
        }
        const fqn = nominal_fqn(found.unwrap())
        self.recycled.set(fqn, RetiredName { id = e.key, fqn = fqn, from_module = false })
        self.nominals.evict(e.key)
    }
}

// Whether any retirement went unclaimed for a module's own definitions - a declared or generated
// name this demand's sources no longer register. Closure retirements (`from_module` false) are
// rebuilt by the body pass and do not count.
fn removed_names(self: &Checker) bool {
    for e in self.recycled {
        if e.value.from_module {
            return true
        }
    }
    return false
}

// ─────────────────────────────────────────────────────────────────────
// Carried-tier diagnostics (RFC-022 section 5): the collect and resolve passes cache what they emit
// per module, and a demand that reuses the module replays the cache instead of re-running the pass.
// ─────────────────────────────────────────────────────────────────────

// Remember the diagnostics `self.diagnostics[from..]` as module `path`'s collect (or resolve)
// output, replacing whatever the module had cached.
fn stash_nominal_diags(self: &Checker, path: String, from: usize, is_collect: bool) {
    let found = module_diags_entry(self, path, from)
    if found.is_none() {
        return
    }
    let entry = found.unwrap()
    if is_collect {
        refill_diags(self, &entry.collect, from)
    } else {
        refill_diags(self, &entry.resolve, from)
    }
}

// Same, for the signature pass's tier.
fn stash_sig_diags(self: &Checker, path: String, from: usize) {
    let found = module_diags_entry(self, path, from)
    if found.is_none() {
        return
    }
    refill_diags(self, &found.unwrap().signatures, from)
}

// Same, for the body slot's capture window.
fn stash_body_diags(self: &Checker, path: String, from: usize) {
    let found = module_diags_entry(self, path, from)
    if found.is_none() {
        return
    }
    refill_diags(self, &found.unwrap().bodies, from)
}

fn replay_body_diags(self: &Checker, path: String) {
    const found = self.nominal_diags.get_ref(path)
    if found.is_none() {
        return
    }
    for &d in found.unwrap().bodies {
        self.diagnostics.push(clone_diag(d))
    }
}

// The module's diag-cache entry, created on first use. Null when there is no entry yet and nothing
// to stash either - an all-clean module never allocates one.
fn module_diags_entry(
    self: &Checker,
    path: String,
    from: usize,
    force: bool = false,
) &ModuleNomDiags? {
    if self.nominal_diags.get_ref(path).is_none() {
        if from == self.diagnostics.len and !force {
            return null
        }
        const idx = self.nominal_diag_keys.len
        self.nominal_diag_keys.push(from_view(path))
        self.nominal_diags.set(
            self.nominal_diag_keys[idx].view,
            ModuleNomDiags {
                collect = list(0),
                resolve = list(0),
                signatures = list(0),
                bodies = list(0),
                resolve_burn = null,
                resolve_refs = list(0),
            },
        )
    }
    return self.nominal_diags.get_ref(path)
}

// Records how many variables module `path`'s resolve pass minted, when that is more than its type
// parameters account for.
// Also takes the pass's logged go-to-definition edges, replayed with the burn.
fn stash_resolve_burn(self: &Checker, path: String, minted: u32, params: u32) {
    const extra = minted != params
    const found = module_diags_entry(self, path, self.diagnostics.len, extra
        or self.ref_log.len > 0)
    if found.is_some() {
        let entry = found.unwrap()
        entry.resolve_burn = if extra { Some(minted) } else { null }
        install(&entry.resolve_refs, replace(&self.ref_log, list(0)))
    }
}

fn refill_diags(self: &Checker, dst: &List(Diagnostic), from: usize) {
    dst.clear()
    for k in from..self.diagnostics.len {
        dst.push(clone_diag(&self.diagnostics[k]))
    }
}

// Replay module `path`'s cached collect (or resolve) diagnostics into the published list, in the
// loop position the pass itself would have emitted them.
fn replay_nominal_diags(self: &Checker, path: String, is_collect: bool) {
    const found = self.nominal_diags.get_ref(path)
    if found.is_none() {
        return
    }
    let entry = found.unwrap()
    if is_collect {
        for &d in entry.collect {
            self.diagnostics.push(clone_diag(d))
        }
        return
    }
    for &d in entry.resolve {
        self.diagnostics.push(clone_diag(d))
    }
}

fn replay_sig_diags(self: &Checker, path: String) {
    const found = self.nominal_diags.get_ref(path)
    if found.is_none() {
        return
    }
    for &d in found.unwrap().signatures {
        self.diagnostics.push(clone_diag(d))
    }
}

// ─────────────────────────────────────────────────────────────────────
// Carried signatures (RFC-022 5c). A module's schemes, templates and constant types carry in the
// registries; what its signature pass records besides those - node types and spans for
// default-value expressions, engine variables for `$T` binds and unannotated constants - is
// captured per module and replayed on a demand that skips the pass.
// ─────────────────────────────────────────────────────────────────────

// Sizes of everything a signature pass can touch, taken before a module's turn.
// `finish_sig_capture` compares them after: a pass whose only recordings are node types, spans and
// resolved literals is fully described by the cache; anything else (a resolved call or operator in
// a default value, a lambda, an anonymous literal, an interpolation) makes the module re-run its
// pass every demand. `lambda` alone covers the lambda and closure tables - every record of either
// happens inside one `next_lambda` mint.
type SigWatermark = struct {
    vars: u32
    synth: u32
    lambda: u32
    lits: usize
    targets: usize
    ops: usize
    desugars: usize
    default_args: usize
    arg_lists: usize
    receiver_derefs: usize
    receiver_adapts: usize
    synth_strings: usize
    instantiated: usize
    pending_specs: usize
    pending_calls: usize
    pending_fn_names: usize
    pending_anons: usize
    pending_members: usize
}

fn sig_watermark(self: &Checker) SigWatermark {
    return .{
        vars = self.engine.var_counter,
        synth = self.next_synth,
        lambda = self.next_lambda,
        lits = self.pending_literals.len,
        targets = self.results.resolved_targets.len(),
        ops = self.results.resolved_ops.len(),
        desugars = self.results.desugars.len(),
        default_args = self.results.default_args.len(),
        arg_lists = self.results.arg_lists.len(),
        receiver_derefs = self.results.receiver_derefs.len(),
        receiver_adapts = self.results.receiver_adapts.len(),
        synth_strings = self.results.synth_strings.len,
        instantiated = self.results.instantiated_types.len,
        pending_specs = self.pending_specs.len,
        pending_calls = self.pending_calls.len,
        pending_fn_names = self.pending_fn_names.len,
        pending_anons = self.pending_anons.len,
        pending_members = self.pending_members.len,
    }
}

// Run one module's signature pass with capture on, stash its diagnostics, and store the cache entry
// for the next demand.
fn run_signature_pass(self: &Checker, module: &Module, path: String, sources: &List(OwnedString)) {
    const w = sig_watermark(self)
    self.sig_nodes.clear()
    self.sig_capture = true
    self.ref_log.clear()
    self.ref_logging = true
    self.ref_new = 0usize
    const diags_from = self.diagnostics.len
    collect_signatures(self, module, path)
    self.sig_capture = false
    self.ref_logging = false
    stash_sig_diags(self, path, diags_from)
    finish_sig_capture(self, path, &w, collect_default_texts(self, module, sources))
}

fn finish_sig_capture(
    self: &Checker,
    path: String,
    w: &SigWatermark,
    default_texts: move List(OwnedString),
) {
    const clean = self.next_synth == w.synth and self.next_lambda == w.lambda
        and self.results.resolved_targets.len() == w.targets + self.ref_new
        and self.results.resolved_ops.len() == w.ops and self.results.desugars.len() == w.desugars
        and self.results.default_args.len() == w.default_args
        and self.results.arg_lists.len() == w.arg_lists
        and self.results.receiver_derefs.len() == w.receiver_derefs
        and self.results.receiver_adapts.len() == w.receiver_adapts
        and self.results.synth_strings.len == w.synth_strings
        and self.results.instantiated_types.len == w.instantiated
        and self.pending_specs.len == w.pending_specs and self.pending_calls.len == w.pending_calls
        and self.pending_fn_names.len == w.pending_fn_names
        and self.pending_anons.len == w.pending_anons
        and self.pending_members.len == w.pending_members

    let facts = replace(&self.sig_nodes, list(0))
    let lit_tys: List(Ty) = list(0)
    for k in w.lits..self.pending_literals.len {
        lit_tys.push(self.pending_literals[k].ty)
    }
    let cache = ModuleSigCache {
        facts = move facts,
        var_burn = (self.engine.var_counter - w.vars) as usize,
        vars_at_start = w.vars,
        lit_tys = move lit_tys,
        refs = replace(&self.ref_log, list(0)),
        default_texts = move default_texts,
        cacheable = clean,
        fresh = true,
    }

    const found = self.sig_caches.get_ref(path)
    if found.is_none() {
        const idx = self.sig_cache_keys.len
        self.sig_cache_keys.push(from_view(path))
        self.sig_caches.set(self.sig_cache_keys[idx].view, cache)
        return
    }
    let slot = found.unwrap()
    if default_texts_differ(&slot.default_texts, &cache.default_texts) {
        self.defaults_changed = true
    }
    install(slot, cache)
}

// Whether module `path`'s signature pass can be skipped this demand: a cache exists, nothing it
// cannot replay was recorded, and the variable stream stands exactly where it stood when the pass
// ran - the carried handles are absolute ids, so any offset makes them someone else's.
fn sig_cache_ok(self: &Checker, path: String, vars_now: u32) bool {
    const found = self.sig_caches.get_ref(path)
    if found.is_none() {
        return false
    }
    const c = found.unwrap()
    return c.cacheable and c.vars_at_start == vars_now
}

// Reproduce what a skipped signature pass would have left behind: the cached diagnostics, the span
// and node-type entries, and the engine variables it would have minted - burned so every later
// phase's variable stream matches a cold check's. The carried registries already hold the pass's
// registrations; the burned variables are what keeps an unannotated constant's carried variable
// naming the slot the constants phase then binds.
fn replay_signature_cache(self: &Checker, path: String) {
    replay_sig_diags(self, path)
    const found = self.sig_caches.get_ref(path)
    if found.is_none() {
        return
    }
    let c = found.unwrap()
    for &f in c.facts {
        self.results.record_span(f.node, f.span)
        f.ty match {
            Some(t) => self.results.record_type(f.node, t)
            None => {}
        }
    }
    replay_type_refs(self, &c.refs)
    for _k in 0..c.var_burn {
        self.engine.burn_var()
    }
}

// Fill this demand's fresh captures with their final types, once the demand's zonk has run: each
// captured node's entry in the zonked table, and a cacheability check on the pass's literals - one
// still unresolved would owe an E2001 per demand, so its module stays uncached and re-runs.
fn harvest_sig_caches(self: &Checker, zonked: &Dict(NodeId, Ty)) {
    for k in 0..self.sig_cache_keys.len {
        const path = self.sig_cache_keys[k].view
        let entry = self.sig_caches.get_ref(path).unwrap()
        if !entry.fresh {
            continue
        }
        entry.fresh = false
        for j in 0..entry.facts.len {
            const f = entry.facts[j]
            entry.facts[j] = SigNodeFact { node = f.node, span = f.span, ty = zonked.get(f.node) }
        }
        for t in entry.lit_tys {
            const z = self.engine.zonk(t)
            if self.engine.is_var(z) {
                entry.cacheable = false
            }
        }
        entry.lit_tys.clear()
    }
}

// Mint what a skipped body resolution would have per type parameter: the fresh variable, so the
// engine's variable stream matches a cold check's (anything keyed by a variable id downstream - an
// anonymous record whose key renders one - depends on that stream), and the parameter's span node,
// so the result's span table holds the same entries. The carried bodies keep the variable ids of
// the demand that resolved them; these stand-ins are never read.
fn burn_type_param_vars(self: &Checker, module: &Module, path: String) {
    const entry = self.nominal_diags.get_ref(path)
    const recorded = if entry.is_some() { entry.unwrap().resolve_burn } else { null }
    if entry.is_some() {
        replay_type_refs(self, &entry.unwrap().resolve_refs)
    }
    if recorded.is_some() {
        for _k in 0..(recorded.unwrap() - type_param_count(module)) {
            self.engine.burn_var()
        }
    }
    for &decl in module.decls {
        decl.* match {
            Type(td) => {
                td.body match {
                    AnonStruct(a) => {
                        for &g in a.generics {
                            const _v = self.engine.fresh_var()
                            const _n = self.node_of(g.span)
                        }
                    }
                    AnonEnum(e) => {
                        for &g in e.generics {
                            const _v = self.engine.fresh_var()
                            const _n = self.node_of(g.span)
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
}

fn type_param_count(module: &Module) u32 {
    let n = 0u32
    for &decl in module.decls {
        const k = decl.* match {
            Type(td) => td.body.* match {
                AnonStruct(a) => a.generics.len
                AnonEnum(e) => e.generics.len
                _ => 0usize
            }
            _ => 0usize
        }
        n = n + k as u32
    }
    return n
}

// ─────────────────────────────────────────────────────────────────────
// Carried bodies (RFC-022 5d). A module the demand did not re-parse replays its body slot from
// `body_caches`: the capture window's facts write back with their harvested final values, the
// counters burn, and the slot's settlement re-runs live from the captured picks and parked calls -
// at the ids and in the order a cold check assigns, re-pinning the module's burned variables the
// way the cold drain did. With the specialization registry carried too (5e), a replayed pick whose
// entry can itself be replayed skips the template body re-check entirely; the rest re-instantiate
// live, in place.
// ─────────────────────────────────────────────────────────────────────

// What a running slot's two timed halves cost, for `CheckPhases`.
type SlotTiming = struct {
    bodies_ns: u64
    settle_ns: u64
}

// Run one module's slot with capture on and store its cache for the next demand.
fn run_body_slot(self: &Checker, module: &Module, path: String) SlotTiming {
    begin_slot_specs(self, path)
    const vars0 = self.engine.var_counter
    const synth0 = self.next_synth
    const lambda0 = self.next_lambda
    const lit0 = self.pending_literals.len
    const calls0 = self.pending_calls.len
    const diags_from = self.diagnostics.len

    const bodies_start = monotonic_ns()
    reset_template_types(self, path)
    self.results.begin_capture()
    check_module_bodies(self, module, path)
    const bodies_ns = elapsed_ns(bodies_start)
    const settle_start = monotonic_ns()
    resolve_anon_literals(self)
    resolve_pending_members(self)
    // A member access the drain has yet to settle unifies live, off the replay's script: the slot
    // re-runs every demand rather than replaying with the receiver open.
    const members_clean = self.pending_members.len == 0
    resolve_fn_name_values(self)
    let keys = self.results.end_capture()
    const var_burn = (self.engine.var_counter - vars0) as usize
    const synth_burn = self.next_synth - synth0
    const lambda_burn = self.next_lambda - lambda0
    const lit_window = self.pending_literals.len
    stash_body_diags(self, path, diags_from)
    let calls = copy_parked_calls(self, calls0)

    clear_pick_log(self)
    self.slot_log_on = true
    self.site_log_on = true
    self.slot_uninferable = 0
    drain_pending_specs(self, false)
    resolve_pending_members(self)
    resolve_pending_calls(self)
    drain_pending_specs(self)
    self.slot_log_on = false
    self.site_log_on = false
    let picks = replace(&self.slot_picks, list(0))
    validate_literals(self, lit0, self.pending_literals.len)
    // The window's literal verdicts cannot be replayed - a flagged one keeps the module running.
    // Decided here, where the verdicts are final (nothing after the slot can pin its literals), so
    // `seal_slot` can retire the slot's entries.
    let lits_clean = true
    for j in lit0..lit_window {
        if literal_flagged(self, &self.pending_literals[j]) {
            lits_clean = false
        }
    }
    mark_flagged_slot_specs(self, lit_window)
    seal_slot(self, lit0)
    let sites = replace(&self.slot_sites, list(0))

    let cache = ModuleBodyCache { vars_at_start = vars0, var_burn = var_burn, synth_at_start = synth0, synth_burn = synth_burn, lambda_at_start = lambda0, lambda_burn = lambda_burn, keys = move keys, types = list(0), spans = list(0), targets = list(0), ops = list(0), desugars = list(0), lambdas = list(0), closures = list(0), default_args = list(0), arg_lists = list(0), derefs = list(0), arg_derefs = list(0), adapts = list(0), picks = move picks, calls = move calls, spec_sites = move sites, cacheable = self.slot_uninferable == 0
        and lits_clean and members_clean, fresh = true }
    store_body_cache(self, path, cache)
    return .{ bodies_ns = bodies_ns, settle_ns = elapsed_ns(settle_start) }
}

// Whether module `path`'s slot can be replayed this demand: a harvested cache exists, nothing
// unreplayable was recorded, and every stream stands exactly where it stood when the slot ran.
fn body_cache_ok(self: &Checker, path: String) bool {
    const found = self.body_caches.get_ref(path)
    if found.is_none() {
        return false
    }
    const c = found.unwrap()
    return c.cacheable and !c.fresh and c.vars_at_start == self.engine.var_counter
        and c.synth_at_start == self.next_synth and c.lambda_at_start == self.next_lambda
}

// Replay module `path`'s slot: cached diagnostics and facts, counter burns, then the settlement
// re-run - the logged picks in their cold process order, the parked calls, and a drain for what
// their resolution commits. The literal sweep covers only what the live re-run minted; the window's
// literals were proven clean when the slot last ran.
fn replay_body_slot(self: &Checker, path: String) SlotTiming {
    begin_slot_specs(self, path)
    const bodies_start = monotonic_ns()
    self.current_module = Some(path)
    replay_body_diags(self, path)
    let c = self.body_caches.get_ref(path).unwrap()
    for &f in c.spans {
        self.results.record_span(f.node, f.span)
    }
    for &f in c.types {
        self.results.record_type(f.node, f.ty)
    }
    for &f in c.targets {
        self.results.record_target(f.node, f.target)
    }
    for &f in c.ops {
        self.results.record_operator(f.node, f.op)
    }
    for &f in c.desugars {
        self.results.record_desugar(f.node, f.block)
    }
    for &f in c.closures {
        replay_closure(self, f)
    }
    for &f in c.lambdas {
        self.results.record_lambda(f.node, copy_lambda(&f.info))
    }
    for &f in c.default_args {
        let exprs: List(&Expr) = list(f.exprs.len)
        exprs.push_all(f.exprs.as_slice())
        self.results.record_default_args(f.node, exprs)
    }
    for &f in c.arg_lists {
        let exprs: List(&Expr) = list(f.exprs.len)
        exprs.push_all(f.exprs.as_slice())
        self.results.record_arg_list(f.node, exprs)
    }
    for &f in c.derefs {
        let chain: List(ResolvedTarget) = list(f.chain.len)
        chain.push_all(f.chain.as_slice())
        self.results.record_receiver_deref(f.node, chain)
    }
    for &f in c.arg_derefs {
        let chain: List(ResolvedTarget) = list(f.chain.len)
        chain.push_all(f.chain.as_slice())
        self.results.record_arg_deref(f.node, chain)
    }
    for &f in c.adapts {
        self.results.record_receiver_adapt(f.node, f.adapt)
    }
    for _k in 0..c.var_burn {
        self.engine.burn_var()
    }
    self.next_synth = self.next_synth + c.synth_burn
    self.next_lambda = self.next_lambda + c.lambda_burn
    const bodies_ns = elapsed_ns(bodies_start)

    const settle_start = monotonic_ns()
    const lit_mark = self.pending_literals.len
    for &cp in c.picks {
        // The pick's lists stay the cache's: lent into the spec for the call and swapped back, so a
        // later replay finds them intact and nothing is copied.
        let p = PendingSpec {
            span = cp.span,
            is_operator = cp.is_operator,
            deref_index = cp.deref_index,
            deref_on_arg = cp.deref_on_arg,
            function_id = cp.function_id,
            tp_binds = dict(),
            inst_params = list(0),
            inst_ret = cp.inst_ret,
            from_parked = false,
            caller_module = cp.caller_module,
        }
        swap(&p.tp_binds, &cp.tp_binds)
        swap(&p.inst_params, &cp.inst_params)
        process_pending(self, &p)
        swap(&p.tp_binds, &cp.tp_binds)
        swap(&p.inst_params, &cp.inst_params)
    }
    for k in 0..c.calls.len {
        self.pending_calls.push(copy_pending_call(self, &c.calls[k], false))
    }
    resolve_pending_members(self)
    resolve_pending_calls(self)
    drain_pending_specs(self)
    validate_literals(self, lit_mark, self.pending_literals.len)
    mark_flagged_slot_specs(self, lit_mark)
    seal_slot(self, lit_mark)
    return .{ bodies_ns = bodies_ns, settle_ns = elapsed_ns(settle_start) }
}

// Ready the per-slot specialization state (RFC-022 5e): the previous demand's site hints for this
// module, an empty site log, and an empty list of the entries this slot instantiates.
fn begin_slot_specs(self: &Checker, path: String) {
    self.slot_hints.clear()
    const found = self.body_caches.get_ref(path)
    if found.is_some() {
        self.slot_hints.push_all(found.unwrap().spec_sites.as_slice())
    }
    self.slot_sites.clear()
    self.slot_new_specs.clear()
}

// A literal minted during the slot's drains that the sweep flagged belongs to some instantiation's
// body; its diagnostic is regenerated by re-running that body, which a reuse skips - so every entry
// this slot instantiated goes non-reusable.
// ponytail: coarse on purpose - the case is rare and per-frame literal ranges are not tracked; mark
// per frame if a profile ever blames it.
fn mark_flagged_slot_specs(self: &Checker, from: usize) {
    let any = false
    for j in from..self.pending_literals.len {
        if literal_flagged(self, &self.pending_literals[j]) {
            any = true
        }
    }
    if !any {
        return
    }
    for id in self.slot_new_specs {
        self.specs.mark_unreusable(id)
    }
}

// A slot leaves no parked work behind: what its settlement could not resolve is abandoned, as the
// single program-wide settlement pass abandoned it before slots existed. Leaking it forward would
// hand one module's leftovers to the next module's slot. The slot's literals retire too - their
// verdicts are final once the slot's sweep has run, so from here on `pending_literals` holds only
// what is genuinely pending: the preamble entries below `lit_floor` (signature defaults and
// constant initializers, swept at phase 3.6) and, mid-slot, the running slot's own. That bound is
// also what keeps `is_literal_var`'s scan short.
fn seal_slot(self: &Checker, lit_floor: usize) {
    self.pending_anons.clear()
    self.pending_members.clear()
    let names = replace(&self.pending_fn_names, list(0))
    names.deinit()
    let calls = replace(&self.pending_calls, list(0))
    for pc in calls.drain() {
        pc.arg_tys.deinit()
        pc.pos_exprs.deinit()
    }
    calls.deinit()
    self.pending_literals.truncate(lit_floor)
}

fn clear_pick_log(self: &Checker) {
    self.slot_picks.clear()
}

// Log one processed top-level pick for the module's cache, its types zonked to this moment.
fn log_pick(self: &Checker, p: &PendingSpec, params: &List(Ty), ret: Ty) {
    let binds: Dict(VarId, Ty) = dict()
    for e in p.tp_binds {
        binds.set(e.key, self.engine.zonk(e.value))
    }
    let ps: List(Ty) = list(params.len)
    ps.push_all(params.as_slice())
    self.slot_picks.push(CapturedPick {
        span = p.span,
        is_operator = p.is_operator,
        deref_index = p.deref_index,
        deref_on_arg = p.deref_on_arg,
        function_id = p.function_id,
        tp_binds = move binds,
        inst_params = move ps,
        inst_ret = ret,
        caller_module = p.caller_module,
    })
}

// The slot's parked calls, copied for the cache with their argument types zonked to the window's
// end - the state resolution starts from. A type still open here re-pins during the replayed drains
// exactly as it did cold, over the same burned variable ids.
fn copy_parked_calls(self: &Checker, from: usize) List(PendingCall) {
    let out: List(PendingCall) = list(self.pending_calls.len - from)
    for k in from..self.pending_calls.len {
        out.push(copy_pending_call(self, &self.pending_calls[k], true))
    }
    return out
}

fn copy_pending_call(self: &Checker, pc: &PendingCall, zonk_args: bool) PendingCall {
    let ats: List(Ty) = list(pc.arg_tys.len)
    for t in pc.arg_tys {
        ats.push(if zonk_args { self.engine.zonk(t) } else { t })
    }
    let pes: List(&Expr) = list(pc.pos_exprs.len)
    pes.push_all(pc.pos_exprs.as_slice())
    const recv = pc.alt_recv match {
        Some(a) => Some(if zonk_args { self.engine.zonk(a) } else { a })
        None => null
    }
    return PendingCall {
        span = pc.span,
        name = pc.name,
        call = pc.call,
        arg_tys = move ats,
        pos_exprs = move pes,
        recv_extra = pc.recv_extra,
        alt_recv = recv,
        module = pc.module,
    }
}

// Register a cached closure environment again at the id it held (its retirement is in `recycled`,
// keyed by the synthesized FQN) and restore its dispatch record.
fn replay_closure(self: &Checker, f: &ClosureFact) {
    let fields: List(Field) = list(f.fields.len)
    fields.push_all(f.fields.as_slice())
    let empty_tps: List(VarId) = list(0)
    let sd = StructDef {
        fqn = "",
        module = f.module,
        is_pub = true,
        type_params = move empty_tps,
        assoc_params = list(0),
        fields = move fields,
        decl_span = f.decl_span,
        deprecation = null,
        is_simd = false,
        is_foreign = false,
    }
    const nid = register_collected(self, NominalDef.NomStruct(move sd), from_view(f.fqn.view))
    self.closures.set(nid, copy_sig(&f.sig))
}

fn store_body_cache(self: &Checker, path: String, cache: move ModuleBodyCache) {
    const found = self.body_caches.get_ref(path)
    if found.is_none() {
        const idx = self.body_cache_keys.len
        self.body_cache_keys.push(from_view(path))
        self.body_caches.set(self.body_cache_keys[idx].view, cache)
        return
    }
    let slot = found.unwrap()
    install(slot, cache)
}

// Fill this demand's fresh body caches from the finished tables, once the final zonk has run.
fn harvest_body_caches(self: &Checker, zonked: &Dict(NodeId, Ty)) {
    for k in 0..self.body_cache_keys.len {
        const path = self.body_cache_keys[k].view
        let entry = self.body_caches.get_ref(path).unwrap()
        if !entry.fresh {
            continue
        }
        entry.fresh = false
        fill_body_cache(self, entry, zonked)
    }
}

fn fill_body_cache(self: &Checker, c: &ModuleBodyCache, zonked: &Dict(NodeId, Ty)) {
    let seen: Set(NodeId) = set()
    for n in c.keys.spans {
        if seen.contains(n) {
            continue
        }
        seen.add(n)
        const sp = self.results.get_span(n)
        if sp.is_some() {
            c.spans.push(NodeSpanFact { node = n, span = sp.unwrap() })
        }
    }
    seen.clear()
    for n in c.keys.types {
        if seen.contains(n) {
            continue
        }
        seen.add(n)
        const t = zonked.get(n)
        if t.is_some() {
            c.types.push(NodeTyFact { node = n, ty = t.unwrap() })
        }
    }
    seen.clear()
    for n in c.keys.targets {
        if seen.contains(n) {
            continue
        }
        seen.add(n)
        const t = self.results.resolved_targets.get(n)
        if t.is_some() {
            c.targets.push(NodeTargetFact { node = n, target = t.unwrap() })
        }
    }
    seen.clear()
    for n in c.keys.ops {
        if seen.contains(n) {
            continue
        }
        seen.add(n)
        const o = self.results.resolved_ops.get(n)
        if o.is_some() {
            c.ops.push(NodeOpFact { node = n, op = o.unwrap() })
        }
    }
    seen.clear()
    for n in c.keys.desugars {
        if seen.contains(n) {
            continue
        }
        seen.add(n)
        const b = self.results.desugars.get(n)
        if b.is_some() {
            c.desugars.push(NodeBlockFact { node = n, block = b.unwrap() })
        }
    }
    seen.clear()
    for n in c.keys.lambdas {
        if seen.contains(n) {
            continue
        }
        seen.add(n)
        const found = self.results.lambdas.get_ref(n)
        if found.is_none() {
            continue
        }
        let info = found.unwrap()
        c.lambdas.push(NodeLambdaFact { node = n, info = copy_lambda(info) })
        info.closure_id match {
            Some(nid) => harvest_closure(self, c, nid)
            None => {}
        }
    }
    seen.clear()
    for n in c.keys.default_args {
        if seen.contains(n) {
            continue
        }
        seen.add(n)
        const found = self.results.default_args.get_ref(n)
        if found.is_some() {
            let exprs: List(&Expr) = list(found.unwrap().len)
            exprs.push_all(found.unwrap().as_slice())
            c.default_args.push(NodeExprsFact { node = n, exprs = move exprs })
        }
    }
    seen.clear()
    for n in c.keys.arg_lists {
        if seen.contains(n) {
            continue
        }
        seen.add(n)
        const found = self.results.arg_lists.get_ref(n)
        if found.is_some() {
            let exprs: List(&Expr) = list(found.unwrap().len)
            exprs.push_all(found.unwrap().as_slice())
            c.arg_lists.push(NodeExprsFact { node = n, exprs = move exprs })
        }
    }
    seen.clear()
    for n in c.keys.derefs {
        if seen.contains(n) {
            continue
        }
        seen.add(n)
        const found = self.results.receiver_derefs.get_ref(n)
        if found.is_some() {
            let chain: List(ResolvedTarget) = list(found.unwrap().len)
            chain.push_all(found.unwrap().as_slice())
            c.derefs.push(NodeDerefsFact { node = n, chain = move chain })
        }
    }
    seen.clear()
    for n in c.keys.arg_derefs {
        if seen.contains(n) {
            continue
        }
        seen.add(n)
        const found = self.results.arg_derefs.get_ref(n)
        if found.is_some() {
            let chain: List(ResolvedTarget) = list(found.unwrap().len)
            chain.push_all(found.unwrap().as_slice())
            c.arg_derefs.push(NodeDerefsFact { node = n, chain = move chain })
        }
    }
    seen.clear()
    for n in c.keys.adapts {
        if seen.contains(n) {
            continue
        }
        seen.add(n)
        const a = self.results.receiver_adapts.get(n)
        if a.is_some() {
            c.adapts.push(NodeAdaptFact { node = n, adapt = a.unwrap() })
        }
    }
    seen.deinit()

    install(&c.keys, captured_keys())
}

// One closure environment's registry definition and dispatch record, copied for the cache. Runs
// after `zonk_closures`, so both hold final types.
fn harvest_closure(self: &Checker, c: &ModuleBodyCache, nid: NominalId) {
    const f = closure_fact_of(self, nid)
    if f.is_some() {
        c.closures.push(f.unwrap())
    }
}

// A registered closure environment as a replayable fact: the definition from the nominal registry,
// the dispatch record from the global closure table. Null when either half is missing.
fn closure_fact_of(self: &Checker, nid: NominalId) ClosureFact? {
    const sig = self.closures.get_ref(nid)
    if sig.is_none() {
        return null
    }
    const found = self.nominals.find(nid)
    if found.is_none() {
        return null
    }
    let def = found.unwrap()
    const sd = def.* match {
        NomStruct(s) => move s
        _ => return null
    }
    let fields: List(Field) = list(sd.fields.len)
    fields.push_all(sd.fields.as_slice())
    return Some(ClosureFact {
        id = nid,
        fqn = from_view(nominal_fqn(def)),
        module = sd.module,
        fields = move fields,
        decl_span = sd.decl_span,
        sig = copy_sig(sig.unwrap()),
    })
}

// Mark every carried specialization whose template module is being re-collected (RFC-022 5e).
fn mark_stale_specs(self: &Checker, retiring: &Set(String)) {
    if retiring.len() == 0 {
        return
    }
    for i in 0..(self.specs.next_id as usize) {
        const found = self.specs.find(i as SpecId)
        if found.is_none() {
            continue
        }
        if retiring.contains(found.unwrap().module) {
            self.specs.mark_stale(i as SpecId)
        }
    }
}

// Fill this demand's fresh specialization caches once the closure tables have zonked: the closure
// facts a reuse replays (recovered through each overlay's lambda records), and the
// signature-concreteness half of `reusable`. Reused entries keep the caches they carried.
fn harvest_spec_caches(self: &Checker) {
    for i in 0..(self.specs.next_id as usize) {
        const found = self.specs.find(i as SpecId)
        if found.is_none() {
            continue
        }
        const sp = found.unwrap()
        if sp.harvested {
            continue
        }
        let facts: List(ClosureFact) = list(0)
        for e in sp.overlay.lambdas {
            e.value.closure_id match {
                Some(nid) => {
                    const f = closure_fact_of(self, nid)
                    if f.is_some() {
                        facts.push(f.unwrap())
                    }
                }
                None => {}
            }
        }
        self.specs.finish_harvest(
            i as SpecId,
            facts,
            sig_concrete(self, &sp.concrete_params, sp.concrete_return),
        )
    }
}

// ─────────────────────────────────────────────────────────────────────
// Signature-tier fingerprints. A carried body baked resolution outcomes - overload picks, field
// indices, constant types, default materializations - so it stays valid only while every registry a
// body resolves against says what it said. Each comparison covers only the re-run modules; a
// skipped pass cannot have changed anything.
// ─────────────────────────────────────────────────────────────────────

// The retiring modules' entries of `map` (the constants, the context fields), name id -> the type
// `ty_of` reads off each. An unannotated constant's type is its variable, which the aligned stream
// re-mints at the same id, so handle equality holds exactly when the entry re-registers the same.
fn snapshot_types(map: &FqnMap($V), retiring: &Set(String), ty_of: $F) Dict(StrId, Ty)
where F: fn(V) Ty {
    let out: Dict(StrId, Ty) = dict()
    for entry in map.entries {
        const fqn = map.name(entry.key)
        if retiring.contains(module_of(fqn, last_dot(fqn))) {
            out.set(entry.key, ty_of(entry.value))
        }
    }
    return out
}

// Whether the retiring modules' entries of `map` changed across the signature phase: one added,
// removed, or re-registered at a different type.
fn types_differ(map: &FqnMap($V), old: &Dict(StrId, Ty), retiring: &Set(String), ty_of: $F) bool
where F: fn(V) Ty {
    let count: usize = 0
    for entry in map.entries {
        const fqn = map.name(entry.key)
        if !retiring.contains(module_of(fqn, last_dot(fqn))) {
            continue
        }
        count = count + 1
        const prev = old.get(entry.key)
        if prev.is_none() or prev.unwrap() != ty_of(entry.value) {
            return true
        }
    }
    return count != old.len()
}

type CtxRow = struct {
    fqn: String
    module: String
    field: CtxField
}

fn cmp_ctx_row(a: CtxRow, b: CtxRow) Ord {
    if a.module != b.module {
        return op_cmp(a.module, b.module)
    }
    return op_cmp(a.field.span.start, b.field.span.start)
}

// Lay out the program's runtime context (RFC-038): every registered field, by module FQN then
// declaration order, becomes a field of `core.runtime.Context`'s definition, whose layout is then
// the context's. Returns the fields' FQNs in that order. Checking never reads these fields -
// `context.f` resolves through `ctx_fields` - so no module's check depends on the assembly.
fn assemble_context(self: &Checker) List(OwnedString) {
    let rows: List(CtxRow) = list(0)
    defer rows.deinit()
    for entry in self.ctx_fields.entries {
        const fqn = self.ctx_fields.name(entry.key)
        rows.push(CtxRow { fqn = fqn, module = module_of(fqn, last_dot(fqn)), field = entry.value })
    }
    rows.sort(cmp_ctx_row)
    let fqns: List(OwnedString) = list(rows.len)
    let fields: List(Field) = list(rows.len)
    for &r in rows {
        fqns.push(from_view(r.fqn))
        fields.push(Field {
            name = r.field.name,
            ty = r.field.ty,
            decl_span = r.field.span,
            owned = false,
        })
    }
    const id = self.nominals.by_fqn.get(FQN_CONTEXT)
    if id.is_none() {
        fields.deinit()
        return fqns
    }
    const def = self.nominals.get(id.unwrap()).* match {
        NomStruct(sd) => Some(StructDef {
            fqn = sd.fqn,
            module = sd.module,
            is_pub = sd.is_pub,
            type_params = list(0),
            assoc_params = list(0),
            fields = move fields,
            decl_span = sd.decl_span,
            deprecation = sd.deprecation,
            is_simd = false,
            is_foreign = false,
        })
        NomEnum(_) => null
    }
    def match {
        Some(d) => self.nominals.replace_body(id.unwrap(), NominalDef.NomStruct(move d))
        None => {}
    }
    return fqns
}

// Whether any module-level constant's variable is still open once the initializers are checked. A
// body can be what pins such a variable, and a skipped body's pinning unification is lost - so an
// open constant sends every body back to source.
fn any_open_constant(self: &Checker) bool {
    for entry in self.constants.entries {
        if self.engine.is_var(self.engine.zonk(entry.value)) {
            return true
        }
    }
    return false
}

// The retiring modules' resolved nominal definitions, FQN -> fingerprint, taken before retirement
// frees the bodies. Compared after re-resolution: a changed field or variant re-types every body
// that touches the nominal (member access bakes field indices, patterns bake variant shapes).
fn snapshot_nominal_defs(self: &Checker, retiring: &Set(String)) Dict(String, OwnedString) {
    let out: Dict(String, OwnedString) = dict()
    for i in 0..(self.nominals.next_id as usize) {
        const found = self.nominals.find(i as NominalId)
        if found.is_none() {
            continue
        }
        const def = found.unwrap()
        if !retiring.contains(nominal_module(def)) {
            continue
        }
        let sb = string_builder(64)
        render_def_fingerprint(def, &sb)
        out.set(nominal_fqn(def), sb.to_string())
    }
    return out
}

fn nominal_defs_differ(self: &Checker, old: &Dict(String, OwnedString)) bool {
    let sb = string_builder(64)
    defer sb.deinit()
    for entry in old {
        const id = self.nominals.lookup_fqn(entry.key)
        if id.is_none() {
            return true
        }
        sb.clear()
        render_def_fingerprint(self.nominals.find(id.unwrap()).unwrap(), &sb)
        if sb.as_view() != entry.value.view {
            return true
        }
    }
    return false
}

// A stable spelling of everything a body's resolution can observe of one nominal: flags, arity,
// field and variant names, and their types as interned handles. Handle equality is type equality
// within one carried table, and the variable stream is position-stable across demands; a spurious
// inequality from an upstream stream shift only over-invalidates.
fn render_def_fingerprint(def: &NominalDef, sb: &StringBuilder) {
    def.* match {
        NomStruct(s) => {
            sb.append("s|")
            sb.append(s.is_pub)
            sb.append(s.is_simd)
            sb.append(s.is_foreign)
            sb.append("|")
            sb.append(s.type_params.len as u64)
            s.deprecation match {
                Some(d) => {
                    sb.append("!")
                    sb.append(d)
                }
                None => {}
            }
            for &fl in s.fields {
                sb.append("|")
                sb.append(fl.name)
                sb.append(":")
                sb.append(fl.ty as u64)
            }
        }
        NomEnum(en) => {
            sb.append("e|")
            sb.append(en.is_pub)
            sb.append("|")
            sb.append(en.type_params.len as u64)
            en.deprecation match {
                Some(d) => {
                    sb.append("!")
                    sb.append(d)
                }
                None => {}
            }
            for &v in en.variants {
                sb.append("|")
                sb.append(v.name)
                for pt in v.payloads {
                    sb.append(":")
                    sb.append(pt as u64)
                }
            }
        }
    }
}

// The source text of each default-value expression a module declares, in declaration order. A
// caller's cached slot holds the callee's default AST and the node types its materializations
// produced, so a value change with an unchanged scheme must still invalidate. Empty when the caller
// supplied no sources (test fixtures), which skips the comparison.
fn collect_default_texts(
    self: &Checker,
    module: &Module,
    sources: &List(OwnedString),
) List(OwnedString) {
    let out: List(OwnedString) = list(0)
    if sources.len == 0 {
        return out
    }
    for &decl in module.decls {
        decl.* match {
            Function(fd) => {
                for &p in fd.params {
                    p.default_value match {
                        Some(d) => out.push(from_view(default_text_of(sources, expr_span(d))))
                        None => {}
                    }
                }
            }
            _ => {}
        }
    }
    return out
}

fn default_text_of(sources: &List(OwnedString), sp: SourceSpan) String {
    if sp.file_id < 0 {
        return ""
    }
    const f = sp.file_id as usize
    if f >= sources.len {
        return ""
    }
    const src = sources[f].view
    if sp.start + sp.length > src.len {
        return ""
    }
    return src[sp.start..sp.start + sp.length]
}

fn default_texts_differ(old: &List(OwnedString), new: &List(OwnedString)) bool {
    if old.len != new.len {
        return true
    }
    for i in 0..old.len {
        if old[i].view != new[i].view {
            return true
        }
    }
    return false
}

// ─────────────────────────────────────────────────────────────────────
// Alias change detection. A carried body baked its aliases in expanded form, so a changed alias
// invalidates every carried body - detected by comparing canonical spellings of the retiring
// modules' alias bodies across the eviction.
// ─────────────────────────────────────────────────────────────────────

// The retiring modules' alias bodies, name id -> canonical spelling. Ids are the alias registry's
// interned names, which eviction leaves in place and a re-registration lands on again. A body with
// no canonical spelling is left out; `aliases_differ` then counts its re-registration as a change,
// which is the safe direction.
fn snapshot_aliases(self: &Checker, retiring: &Set(String)) Dict(StrId, OwnedString) {
    let out: Dict(StrId, OwnedString) = dict()
    for entry in self.aliases.entries {
        const fqn = self.aliases.name(entry.key)
        const dot = last_dot(fqn)
        if !retiring.contains(module_of(fqn, dot)) {
            continue
        }
        let sb = string_builder(32)
        const body = &entry.value
        if !render_alias_body(body, &sb) {
            sb.deinit()
            continue
        }
        out.set(entry.key, sb.to_string())
    }
    return out
}

// Whether the retiring modules' aliases changed across re-collection: one added, one removed, one
// whose body spells differently, or one whose body cannot be spelled at all.
fn aliases_differ(self: &Checker, old: &Dict(StrId, OwnedString), retiring: &Set(String)) bool {
    let current: usize = 0
    for entry in self.aliases.entries {
        const fqn = self.aliases.name(entry.key)
        const dot = last_dot(fqn)
        if !retiring.contains(module_of(fqn, dot)) {
            continue
        }
        current = current + 1
        const prev = old.get_ref(entry.key)
        if prev.is_none() {
            return true
        }
        let sb = string_builder(32)
        defer sb.deinit()
        const body = &entry.value
        if !render_alias_body(body, &sb) {
            return true
        }
        if sb.as_view() != prev.unwrap().view {
            return true
        }
    }
    return current != old.len()
}

// A canonical spelling of an alias body, for comparison across demands only. False for a shape it
// cannot spell out - the caller treats that as a change.
fn render_alias_body(t: &TypeExpr, sb: &StringBuilder) bool {
    return t.* match {
        Named(n) => {
            sb.append(n.name)
            let ok = true
            if n.generic_args.len > 0 {
                sb.append("(")
                for i in 0..n.generic_args.len {
                    if i > 0 {
                        sb.append(", ")
                    }
                    if !render_alias_body(&n.generic_args[i], sb) {
                        ok = false
                    }
                }
                sb.append(")")
            }
            for &a in n.assoc_args {
                sb.append(if a.pinned { "|=" } else { "|:" })
                sb.append(a.name)
                sb.append(" ")
                if !render_alias_body(a.ty, sb) {
                    ok = false
                }
            }
            ok
        }
        Combined(c) => {
            let ok = true
            for i in 0..c.parts.len {
                if i > 0 {
                    sb.append(" + ")
                }
                if !render_alias_body(&c.parts[i], sb) {
                    ok = false
                }
            }
            ok
        }
        Projection(p) => {
            const ok = render_alias_body(p.base, sb)
            sb.append(".")
            sb.append(p.name)
            ok
        }
        GenericBind(g) => {
            sb.append("$")
            sb.append(g.name)
            true
        }
        Reference(r) => {
            sb.append("&")
            render_alias_body(r.inner, sb)
        }
        Optional(o) => {
            const ok = render_alias_body(o.inner, sb)
            sb.append("?")
            ok
        }
        Array(a) => {
            sb.append("[")
            const eok = render_alias_body(a.element, sb)
            sb.append("; ")
            const lok = render_array_len(a.length, sb)
            sb.append("]")
            eok and lok
        }
        Slice(s) => {
            const ok = render_alias_body(s.element, sb)
            sb.append("[]")
            ok
        }
        Tuple(tu) => {
            sb.append("(")
            let ok = true
            for i in 0..tu.elements.len {
                if i > 0 {
                    sb.append(", ")
                }
                if !render_alias_body(&tu.elements[i], sb) {
                    ok = false
                }
            }
            sb.append(")")
            ok
        }
        Function(f) => {
            sb.append("fn(")
            let ok = true
            for i in 0..f.params.len {
                if i > 0 {
                    sb.append(", ")
                }
                if !render_alias_body(&f.params[i], sb) {
                    ok = false
                }
            }
            sb.append(")")
            f.return_type match {
                Some(rt) => {
                    sb.append(" ")
                    if !render_alias_body(rt, sb) {
                        ok = false
                    }
                }
                None => {}
            }
            ok
        }
        _ => false
    }
}

// An array length spells out as its literal text or the constant name it cites; any other
// expression has no canonical spelling.
fn render_array_len(e: &Expr, sb: &StringBuilder) bool {
    return e.* match {
        Lit(l) => l.value match {
            Int(i) => {
                sb.append(i.text)
                true
            }
            _ => false
        }
        Identifier(id) => {
            sb.append(id.name)
            true
        }
        _ => false
    }
}

// The module indices to walk, in order. A caller that supplies none gets source order; a supplied
// order is filtered to the modules that exist and backfilled, so a stale or partial order can never
// drop a module from the check.
fn visit_sequence(self: &Checker, n: usize, order: &List(usize)?) List(usize) {
    let seq = list(n)
    if order.is_none() {
        for i in 0..n {
            seq.push(i)
        }
        return seq
    }
    let seen = list(n)
    defer seen.deinit()
    for _i in 0..n {
        seen.push(false)
    }
    for i in order.unwrap() {
        if i >= n or seen[i] {
            continue
        }
        seen[i] = true
        seq.push(i)
    }
    for i in 0..n {
        if !seen[i] {
            seq.push(i)
        }
    }
    return seq
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

fn parse_src(src: String, fid: i32) Module {
    let lx = lexer(src)
    let tokens = lx.tokenize()
    let p = parser(tokens, src)
    let cst = p.tree.node_at(p.parse_module())
    let m = project_module(cst, fid)
    p.deinit()
    return m
}

// Error counts of two demands on one checker over modules `b` then `a`: a first check of {b_first,
// a_src}, then a re-demand with only `b` re-parsed as `b_again` - the analyze-layer choreography
// (begin_demand, interner adoption, recollect flags) spelled out at the check_all level.
type RedemandErrors = struct {
    first: usize
    second: usize
}

fn redemand_errors(b_first: String, b_again: String, a_src: String) RedemandErrors {
    let mods = list(2)
    mods.push(parse_src(b_first, 0i32))
    mods.push(parse_src(a_src, 1i32))
    let ps: List(String) = list(2)
    ps.push("b")
    ps.push("a")

    let chk = checker()
    let gen_srcs: List(OwnedString) = list(0)
    let gen_fps: List(OwnedString) = list(0)
    let gens = template_state()
    let res1 = check_all(&chk, &mods, &ps, &gen_srcs, &gen_fps, &gens)
    const first = count_error_diags(&chk.diagnostics)

    chk.begin_demand()
    chk.adopt_interner(take_interner(&res1))
    chk.adopt_specs(take_specs(&res1))
    // Exchanged in place: the slot always holds a valid module and the old one leaves as a value.
    let old_b = parse_src(b_again, 0i32)
    swap(&mods[0], &old_b)
    let recollect: List(bool) = list(2)
    recollect.push(true)
    recollect.push(false)
    let gens2 = template_state()
    let res2 = check_all(&chk, &mods, &ps, &gen_srcs, &gen_fps, &gens2, null, Some(&recollect))
    const second = count_error_diags(&chk.diagnostics)

    res1.deinit()
    res2.deinit()
    chk.deinit()
    old_b.deinit()
    mods.deinit()
    ps.deinit()
    recollect.deinit()
    return .{ first = first, second = second }
}

fn count_error_diags(diags: &List(Diagnostic)) usize {
    let errors = 0usize
    for i in 0..diags.len {
        if diags[i].severity == Severity.Error {
            errors = errors + 1
        }
    }
    return errors
}

test "a changed alias invalidates a carried body" {
    // Module a's struct field baked `Size` in expanded form; editing the alias in module b must
    // re-resolve a's body, surfacing the f64-vs-i32 return mismatch. A carried body left stale
    // would keep i32 and stay silent.
    let r = redemand_errors(
        "pub type Size = i32\n",
        "pub type Size = f64\n",
        "import b\ntype H = struct { s: Size }\nfn f(h: H) i32 { return h.s }\n",
    )
    assert_eq(r.first, 0 as usize, "the i32 alias type-checks")
    assert_true(r.second > 0, "the f64 alias re-resolves the carried body and errors")
}

test "a carried body replays its cached diagnostics" {
    // The duplicate-field error lives in module a's body resolution. Re-demanding with only b dirty
    // skips that pass for a, so the error must come from the per-module cache, not from re-running
    // it.
    let r = redemand_errors(
        "pub fn helper() i32 { return 1 }\n",
        "pub fn helper() i32 { return 2 }\n",
        "type H = struct { x: i32\nx: i32 }\nfn main() i32 { return 0 }\n",
    )
    assert_eq(r.first, 1 as usize, "the duplicate field is reported cold")
    assert_eq(r.second, 1 as usize, "and exactly once again on the re-demand")
}

test "a carried signature replays its cached diagnostics" {
    // The duplicate-signature error (E2103) lives in module a's signature pass. Re-demanding with
    // only b dirty skips that pass for a, so the error must come from the signature tier's cache.
    let r = redemand_errors(
        "pub fn helper() i32 { return 1 }\n",
        "pub fn helper() i32 { return 2 }\n",
        "fn dup(x: i32) i32 { return x }\nfn dup(x: i32) i32 { return x }\nfn main() i32 { return 0 }\n",
    )
    assert_eq(r.first, 1 as usize, "the duplicate signature is reported cold")
    assert_eq(r.second, 1 as usize, "and exactly once again on the re-demand")
}

test "an edited signature re-resolves its callers" {
    // Module a's call re-checks against the registry, so b's re-collected signature must have
    // replaced the carried one - a stale scheme would keep the zero-argument call resolving.
    let r = redemand_errors(
        "pub fn helper() i32 { return 1 }\n",
        "pub fn helper(x: i32) i32 { return x }\n",
        "import b\nfn main() i32 { return helper() }\n",
    )
    assert_eq(r.first, 0 as usize, "the zero-argument call resolves cold")
    assert_true(r.second > 0, "the new arity makes the old call an error")
}

test "a removed function stops resolving" {
    // The unclaimed retirement must be purged, not left resolving at its old id.
    let r = redemand_errors(
        "pub fn helper() i32 { return 1 }\n",
        "pub fn other() i32 { return 2 }\n",
        "import b\nfn main() i32 { return helper() }\n",
    )
    assert_eq(r.first, 0 as usize, "the call resolves while the function exists")
    assert_true(r.second > 0, "naming the removed function is reported")
}

test "an upstream shift in the variable stream re-anchors a carried constant" {
    // Demand 1: module b's signature pass mints no variables, so module a's unannotated constant
    // holds the stream's first id. Demand 2: the edited b now mints one (the default literal,
    // pinned i32), so a's carried handle names b's variable. Replaying a's cache would bind the
    // float initializer against that i32 and error; the position check forces a's pass to re-run
    // and re-anchor instead.
    let r = redemand_errors(
        "pub fn helper() i32 { return 1 }\n",
        "pub fn helper(pad: i32 = 7) i32 { return pad }\n",
        "const F = 1.5\nfn main() f64 { return F }\n",
    )
    assert_eq(r.first, 0 as usize, "the float constant type-checks cold")
    assert_eq(r.second, 0 as usize, "and still does once b mints a variable before it")
}

test "carried constants and default values survive a re-demand" {
    // Module a is skipped whole in the signature tier: `scaled`'s scheme and default carry, and
    // LOCAL's variable is re-minted by the burn and re-bound by the constants pass. Any of those
    // going stale surfaces as a spurious error on the re-demand.
    let r = redemand_errors(
        "pub fn helper() i32 { return 1 }\n",
        "pub fn helper() i32 { return 2 }\n",
        "fn scaled(x: i32, k: i32 = 2) i32 { return x }\nconst LOCAL = 3\nfn main() i32 { return scaled(LOCAL) }\n",
    )
    assert_eq(r.first, 0 as usize, "the program type-checks cold")
    assert_eq(r.second, 0 as usize, "and identically on the re-demand")
}

test "a carried slot restores its closures and specializations" {
    // Module a's slot forces a specialization and registers a capturing closure. Re-demanding with
    // only b dirty replays the slot: the pick log re-instantiates `id` and the closure environment
    // re-registers at the id its retirement remembers. Any of that going stale surfaces as a
    // spurious error.
    let r = redemand_errors(
        "pub fn helper() i32 { return 1 }\n",
        "pub fn helper() i32 { return 2 }\n",
        "fn id(x: move $T) $T { return x }\nfn main() i32 {\n    const k = 2\n    let f = fn(x: i32) i32 { x + k }\n    return id(5)\n}\n",
    )
    assert_eq(r.first, 0 as usize, "the program type-checks cold")
    assert_eq(r.second, 0 as usize, "and identically when the slot replays")
}

test "a body-tier diagnostic replays from the slot cache" {
    // The mismatch lives in module a's body window. Re-demanding with only b dirty replays a's
    // slot, so the error must come from the slot's cached diagnostics, not from re-running it.
    let r = redemand_errors(
        "pub fn helper() i32 { return 1 }\n",
        "pub fn helper() i32 { return 2 }\n",
        "fn wrong() i32 { let t = (1i32, 2i32)\nreturn t }\nfn main() i32 { return 0 }\n",
    )
    assert_eq(r.first, 1 as usize, "the mismatch is reported cold")
    assert_eq(r.second, 1 as usize, "and exactly once again on the replay")
}

test "a changed field type re-runs carried bodies" {
    // Module a's member access baked P.v as i32. The re-collected P reclaims its id, so name-set
    // checks see nothing; the definition fingerprint is what must notice and send a's body back to
    // source, where the f64 field breaks the i32 return.
    let r = redemand_errors(
        "pub type P = struct { v: i32 }\n",
        "pub type P = struct { v: f64 }\n",
        "import b\nfn f(p: P) i32 { return p.v }\nfn main() i32 { return 0 }\n",
    )
    assert_eq(r.first, 0 as usize, "the i32 field type-checks")
    assert_true(r.second > 0, "the f64 field re-resolves the carried body and errors")
}

test "an upstream body edit re-anchors the carried slots" {
    // Demand 2's b mints a different number of body-tier variables, which shifts every later slot's
    // stream position; the anchors force those slots to re-run rather than replay handles that now
    // name someone else's variables.
    let r = redemand_errors(
        "pub fn helper() i32 { return 1 }\n",
        "pub fn helper() i32 { let z = 2\nreturn z }\n",
        "fn id(x: move $T) $T { return x }\nfn main() i32 { return id(5) }\n",
    )
    assert_eq(r.first, 0 as usize, "the program type-checks cold")
    assert_eq(r.second, 0 as usize, "and identically once the stream shifts")
}

test "a changed default value invalidates the carried slots" {
    // The scheme compare cannot see a default's VALUE change - same name, same types, same arity -
    // so the signature pass compares the defaults' source text and flags the demand.
    const b1 = "pub fn helper(k: i32 = 1) i32 { return k }\n"
    const b2 = "pub fn helper(k: i32 = 2) i32 { return k }\n"
    const a_src = "import b\nfn main() i32 { return helper() }\n"
    let mods = list(2)
    mods.push(parse_src(b1, 0i32))
    mods.push(parse_src(a_src, 1i32))
    let ps: List(String) = list(2)
    ps.push("b")
    ps.push("a")
    let srcs: List(OwnedString) = list(2)
    srcs.push(from_view(b1))
    srcs.push(from_view(a_src))
    let fps: List(OwnedString) = list(2)
    fps.push(from_view("b"))
    fps.push(from_view("a"))

    let chk = checker()
    let gens = template_state()
    let res1 = check_all(&chk, &mods, &ps, &srcs, &fps, &gens)
    assert_eq(count_error_diags(&chk.diagnostics), 0 as usize, "the defaulted call type-checks")
    assert_true(!chk.defaults_changed, "a first demand flags nothing")

    chk.begin_demand()
    chk.adopt_interner(take_interner(&res1))
    chk.adopt_specs(take_specs(&res1))
    // Exchanged in place: the slot always holds a valid module and the old one leaves as a value.
    let old_b = parse_src(b2, 0i32)
    swap(&mods[0], &old_b)
    // Exchanged in place: the slot always holds a valid source and the old one leaves as a value.
    let old_src = from_view(b2)
    swap(&srcs[0], &old_src)
    let recollect: List(bool) = list(2)
    recollect.push(true)
    recollect.push(false)
    let gens2 = template_state()
    let res2 = check_all(&chk, &mods, &ps, &srcs, &fps, &gens2, null, Some(&recollect))
    assert_eq(count_error_diags(&chk.diagnostics), 0 as usize, "the new value type-checks")
    assert_true(chk.defaults_changed, "the text comparison flags the changed default")

    res1.deinit()
    res2.deinit()
    chk.deinit()
    old_b.deinit()
    old_src.deinit()
    mods.deinit()
    ps.deinit()
    srcs.deinit()
    fps.deinit()
    recollect.deinit()
}

test "an edited template body re-instantiates carried specializations" {
    // Module b's generic body changes without its scheme changing, so no global invalidation fires;
    // the stale marking on the carried specialization is what forces the re-check that reports the
    // f64-vs-i32 mismatch.
    let r = redemand_errors(
        "pub fn pick(x: move $T) $T { return x }\n",
        "pub fn pick(x: move $T) $T { const bad: i32 = 1.5\nreturn x }\n",
        "import b\nfn main() i32 { return pick(5) }\n",
    )
    assert_eq(r.first, 0 as usize, "the original template type-checks")
    assert_true(r.second > 0, "the edited body re-instantiates and reports")
}

test "a specialization diagnostic re-emits on every demand" {
    // The error lives inside the template body, so it surfaces per instantiation. The frame that
    // emitted it is non-reusable; the replayed slot's pick re-instantiates it in place, and the
    // diagnostic count stays stable instead of dropping to zero or doubling.
    let r = redemand_errors(
        "pub fn helper() i32 { return 1 }\n",
        "pub fn helper() i32 { return 2 }\n",
        "fn bad(x: $T) i32 { const oops: i32 = 1.5\nreturn 0 }\nfn main() i32 { return bad(5i32) }\n",
    )
    assert_eq(r.first, 1 as usize, "the template-body error is reported cold")
    assert_eq(r.second, 1 as usize, "and exactly once again on the replay")
}

test "an uninferable literal in a template body reports on every demand" {
    // The E2001 fires in the slot's drain range, outside the capture window, so the module's own
    // cache stays valid and only the flagged-literal marking keeps the specialization from being
    // reused with its diagnostic silently dropped.
    let r = redemand_errors(
        "pub fn helper() i32 { return 1 }\n",
        "pub fn helper() i32 { return 2 }\n",
        "fn f(x: $T) i32 { let v = 1\nreturn 0 }\nfn main() i32 { return f(2i32) }\n",
    )
    assert_eq(r.first, 1 as usize, "the unpinned literal is reported cold")
    assert_eq(r.second, 1 as usize, "and exactly once again on the replay")
}

test "a reused specialization replays its closure environment" {
    // The capturing closure lives inside the template body, so its environment registers per
    // instantiation - a reused entry must re-register it at the id it held, or the re-demand
    // diverges.
    let r = redemand_errors(
        "pub fn helper() i32 { return 1 }\n",
        "pub fn helper() i32 { return 2 }\n",
        "fn wrap(x: $T) i32 {\n    const k = 1i32\n    let f = fn(y: i32) i32 { y + k }\n    return 0\n}\nfn main() i32 { return wrap(4i32) }\n",
    )
    assert_eq(r.first, 0 as usize, "the program type-checks cold")
    assert_eq(r.second, 0 as usize, "and identically when the entry is reused")
}

test "a carried specialization keeps its id across a clean re-demand" {
    const b_src = "pub fn helper() i32 { return 1 }\n"
    const a_src = "import b\nfn id(x: move $T) $T { return x }\nfn main() i32 { return id(5) }\n"
    let mods = list(2)
    mods.push(parse_src(b_src, 0i32))
    mods.push(parse_src(a_src, 1i32))
    let ps: List(String) = list(2)
    ps.push("b")
    ps.push("a")

    let chk = checker()
    let gen_srcs: List(OwnedString) = list(0)
    let gen_fps: List(OwnedString) = list(0)
    let gens = template_state()
    let res1 = check_all(&chk, &mods, &ps, &gen_srcs, &gen_fps, &gens)
    assert_eq(res1.specializations.len(), 1 as usize, "the call forces one specialization")
    const next1 = res1.specializations.next_id

    chk.begin_demand()
    chk.adopt_interner(take_interner(&res1))
    chk.adopt_specs(take_specs(&res1))
    let old_b = parse_src(b_src, 0i32)
    swap(&mods[0], &old_b)
    let recollect: List(bool) = list(2)
    recollect.push(true)
    recollect.push(false)
    let gens2 = template_state()
    let res2 = check_all(&chk, &mods, &ps, &gen_srcs, &gen_fps, &gens2, null, Some(&recollect))
    assert_eq(count_error_diags(&chk.diagnostics), 0 as usize, "the re-demand stays clean")
    assert_eq(res2.specializations.len(), 1 as usize, "still exactly one specialization")
    assert_eq(res2.specializations.next_id, next1, "and no id was minted past it")

    res1.deinit()
    res2.deinit()
    chk.deinit()
    old_b.deinit()
    mods.deinit()
    ps.deinit()
    recollect.deinit()
}

test "a removed call site sweeps its specialization" {
    const b_src = "pub fn pick(x: move $T) $T { return x }\n"
    const a1 = "import b\nfn main() i32 { return pick(5) }\n"
    const a2 = "import b\nfn main() i32 { return 5 }\n"
    let mods = list(2)
    mods.push(parse_src(b_src, 0i32))
    mods.push(parse_src(a1, 1i32))
    let ps: List(String) = list(2)
    ps.push("b")
    ps.push("a")

    let chk = checker()
    let gen_srcs: List(OwnedString) = list(0)
    let gen_fps: List(OwnedString) = list(0)
    let gens = template_state()
    let res1 = check_all(&chk, &mods, &ps, &gen_srcs, &gen_fps, &gens)
    assert_eq(res1.specializations.len(), 1 as usize, "the call forces one specialization")

    chk.begin_demand()
    chk.adopt_interner(take_interner(&res1))
    chk.adopt_specs(take_specs(&res1))
    let old_a = parse_src(a2, 1i32)
    swap(&mods[1], &old_a)
    let recollect: List(bool) = list(2)
    recollect.push(false)
    recollect.push(true)
    let gens2 = template_state()
    let res2 = check_all(&chk, &mods, &ps, &gen_srcs, &gen_fps, &gens2, null, Some(&recollect))
    assert_eq(count_error_diags(&chk.diagnostics), 0 as usize, "the edited caller type-checks")
    assert_eq(
        res2.specializations.len(),
        0 as usize,
        "the entry nothing demanded any more is swept",
    )

    res1.deinit()
    res2.deinit()
    chk.deinit()
    old_a.deinit()
    mods.deinit()
    ps.deinit()
    recollect.deinit()
}

// Parse each source as its own module, run check_all over them, and count error diagnostics.
fn count_check_errors(srcs: String[], paths: String[]) usize {
    let mods = list(srcs.len)
    for i in 0..srcs.len {
        mods.push(parse_src(srcs[i], i as i32))
    }
    let ps = list(paths.len)
    ps.push_all(paths)

    let chk = checker()
    let gen_srcs: List(OwnedString) = list(0)
    let gen_fps: List(OwnedString) = list(0)
    let gens = template_state()
    let _res = check_all(&chk, &mods, &ps, &gen_srcs, &gen_fps, &gens)
    let errors = count_error_diags(&chk.diagnostics)

    chk.deinit()
    mods.deinit()
    ps.deinit()
    return errors
}

test "non-generic type alias resolves cross-module" {
    // `alias_a` declares `type VarId = u32`; `alias_b` imports it and uses the alias in a
    // signature. Before the alias registry, `VarId` surfaced as E2003 unknown type, so a clean run
    // (zero errors) is the regression.
    let errors = count_check_errors(
        ["pub type VarId = u32\n", "import alias_a\nfn f(x: VarId) u32 { return x }\n"],
        ["alias_a", "alias_b"],
    )
    assert_true(errors == 0, "cross-module alias program type-checks with no errors")
}

test "payload variant construction type-checks" {
    // Qualified single- and multi-payload construction on a non-generic enum. Before this fix the
    // callee's receiver checked as a value and surfaced E2004 unknown identifier.
    let errors = count_check_errors(
        [
            "pub type Shape = enum { Dot\nCircle(i32)\nRect(i32, i32) }\nfn f() Shape { return Shape.Circle(3) }\nfn g() Shape { return Shape.Rect(1, 2) }\n",
        ],
        ["shapes"],
    )
    assert_true(errors == 0, "payload variant construction type-checks with no errors")
}

test "generic and unqualified variant construction type-checks" {
    // Generic enum: qualified `Opt.S(3)`, unqualified `S(3)`, and bare payload-less `N` in
    // expression position - each instantiates the enum's type param fresh and unifies it via the
    // declared return.
    let errors = count_check_errors(
        [
            "pub type Opt = enum(T) { N\nS(T) }\nfn f() Opt(i32) { return Opt.S(3) }\nfn g() Opt(i32) { return S(3) }\nfn h() Opt(i32) { return N }\n",
        ],
        ["opts"],
    )
    assert_true(
        errors == 0,
        "generic and unqualified variant construction type-checks with no errors",
    )
}

test "variant payload type mismatch is reported" {
    // A float payload against an i32 variant - no coercion path exists (bool would widen: bool
    // coerces to any integer by design; a string literal resolves to Error poison in these
    // stdlib-less tests).
    let errors = count_check_errors(
        ["pub type Shape = enum { Circle(i32) }\nfn f(x: f64) Shape { return Shape.Circle(x) }\n"],
        ["shapes"],
    )
    assert_true(errors > 0, "f64 payload against i32 variant reports a type error")
}

test "module-level constants resolve cross-module" {
    // An imported `pub const` and a same-module unannotated const both resolve as identifiers;
    // before the constant registry each surfaced E2004 unknown identifier.
    let errors = count_check_errors(
        [
            "pub const LIMIT: u32 = 8\n",
            "import consts_a\nconst LOCAL = 3\nfn f() u32 { return LIMIT }\nfn g() u32 { return LOCAL }\n",
        ],
        ["consts_a", "consts_b"],
    )
    assert_true(errors == 0, "constant reads type-check with no errors")
}

test "qualified payload-less enum variant access type-checks" {
    // `Ord.Less` is a MemberAccess on a type-name receiver. Before this fix the receiver checked as
    // a value and surfaced E2004 unknown identifier; a clean run (zero errors) returning the enum
    // type is the regression.
    let errors = count_check_errors(
        [
            "pub type Ord = enum { Less = -1\nEqual = 0\nGreater = 1 }\nfn f() Ord { return Ord.Less }\n",
        ],
        ["cmp"],
    )
    assert_true(errors == 0, "qualified enum variant access type-checks with no errors")
}

test "direct call unifies args and returns the instantiated type" {
    let errors = count_check_errors(
        ["fn add(a: i32, b: i32) i32 { return a }\nfn f() i32 { return add(1, 2) }\n"],
        ["calls_direct"],
    )
    assert_true(errors == 0, "direct call type-checks with no errors")
}

test "overloads pick the arity-matching candidate" {
    let errors = count_check_errors(
        [
            "fn pick(a: i32) i32 { return a }\nfn pick(a: i32, b: i32) i32 { return b }\nfn f() i32 { return pick(1) }\nfn g() i32 { return pick(1, 2) }\n",
        ],
        ["calls_arity"],
    )
    assert_true(errors == 0, "arity overload resolution type-checks with no errors")
}

test "trailing default params may be omitted at the call site" {
    let errors = count_check_errors(
        [
            "fn scaled(a: i32, k: i32 = 2) i32 { return a }\nfn f() i32 { return scaled(3) }\nfn g() i32 { return scaled(3, 4) }\n",
        ],
        ["calls_defaults"],
    )
    assert_true(errors == 0, "defaulted-param calls type-check with no errors")
}

test "ufcs receiver becomes the first argument, adapted between value and ref" {
    let errors = count_check_errors(
        [
            "pub type Pt = struct { x: i32 }\nfn shift(p: &Pt, d: i32) i32 { return d }\nfn f(p: &Pt) i32 { return p.shift(2) }\nfn g(p: Pt) i32 { return p.shift(2) }\n",
        ],
        ["calls_ufcs"],
    )
    assert_true(errors == 0, "ufcs calls type-check with no errors")
}

test "func-typed struct field dispatches as an indirect call" {
    let errors = count_check_errors(
        ["pub type Ops = struct { scale: fn(i32) i32 }\nfn f(o: &Ops) i32 { return o.scale(3) }\n"],
        ["calls_field"],
    )
    assert_true(errors == 0, "field call type-checks with no errors")
}

test "func-typed param called by name is an indirect call" {
    let errors = count_check_errors(
        ["fn apply(op: fn(i32) i32, x: i32) i32 { return op(x) }\n"],
        ["calls_indirect"],
    )
    assert_true(errors == 0, "indirect call through a param type-checks with no errors")
}

test "wrong argument type in a call is reported" {
    // f64 against i32 has no coercion path (bool would widen by design; string literals are Error
    // poison in these stdlib-less tests).
    let errors = count_check_errors(
        ["fn takes(a: i32) i32 { return a }\nfn f(x: f64) i32 { return takes(x) }\n"],
        ["calls_mismatch"],
    )
    assert_true(errors > 0, "f64 argument against i32 param reports an error")
}

test "a ref-form index operator types as its pointee" {
    let errors = count_check_errors(
        [
            "type Box = struct { v: i32 }\nfn op_index_ref(b: &Box, i: usize) &i32 { return &b.v }\nfn f(b: &Box) i32 { return b[0usize] }\n",
        ],
        ["ix_ref"],
    )
    assert_true(errors == 0, "`&T` return means the index yields `T`")
}

test "a value-form index operator types as its return" {
    let errors = count_check_errors(
        [
            "type Box = struct { v: i32 }\nfn op_index(b: &Box, i: usize) i32 { return b.v }\nfn f(b: &Box) i32 { return b[0usize] }\n",
        ],
        ["ix_val"],
    )
    assert_true(errors == 0, "the operator's return type is the index's type")
}

test "indexing a type with no operator is reported" {
    let errors = count_check_errors(
        ["type Box = struct { v: i32 }\nfn f(b: &Box) i32 { return b[0usize] }\n"],
        ["ix_none"],
    )
    assert_true(errors == 1, "a non-indexable base is E2028, not a silent fresh var")
}

test "a generic struct literal named without type arguments is E2019" {
    let errors = count_check_errors(
        [
            "type Pair = struct(T) { a: T, b: T }\nfn f() i64 { let p = Pair { a = 1i64, b = 2i64 } return p.a }\n",
        ],
        ["underinst"],
    )
    assert_true(errors >= 1, "a named generic literal must spell its arguments (or use `.{ ... }`)")
}

test "a generic struct literal with explicit arguments checks clean" {
    let errors = count_check_errors(
        [
            "type Pair = struct(T) { a: T, b: T }\nfn f() i64 { let p = Pair(i64) { a = 1, b = 2 } return p.a }\n",
        ],
        ["inst"],
    )
    assert_true(errors == 0, "explicit arguments instantiate the literal")
}

test "a bool index is rejected before any operator lookup" {
    let errors = count_check_errors(
        [
            "type Box = struct { v: i32 }\nfn op_index(b: &Box, i: bool) i32 { return b.v }\nfn f(b: &Box) i32 { return b[true] }\n",
        ],
        ["ix_bool"],
    )
    assert_true(errors == 1, "`bool` never indexes, even where an overload would take it")
}

// There is no implicit `T -> Option(T)` wrap: a value arm joining a `null` arm must say `Some(v)`
// explicitly, in either arm order. A real
// `core.option` module is part of each test program — without it the
// registry has no Option, `null` types as `TY_ERROR`, and every outcome passes vacuously.
const OPTION_SRC: String = "pub type Option = enum(T) {\n    None,\n    Some(T),\n}\n"

test "match arms join a Some arm and a null arm into an optional" {
    let errors = count_check_errors(
        [
            OPTION_SRC,
            "import core.option\ntype E = enum { A(i32) B }\nfn f(e: &E) i32? { return e.* match { A(v) => Some(v), B => null } }\nfn g(e: &E) i32? { return e.* match { B => null, A(v) => Some(v) } }\n",
        ],
        ["core.option", "arm_join"],
    )
    assert_true(errors == 0, "explicit Some joins with null in either arm order")
}

test "a bare value arm does not implicitly wrap into an optional" {
    let errors = count_check_errors(
        [
            OPTION_SRC,
            "import core.option\ntype E = enum { A(i32) B }\nfn f(e: &E) i32? { return e.* match { A(v) => v, B => null } }\n",
        ],
        ["core.option", "arm_bare"],
    )
    assert_true(errors > 0, "`T` never becomes `Option(T)` without `Some`")
}

test "if/else branches join the same way match arms do" {
    let errors = count_check_errors(
        [
            OPTION_SRC,
            "import core.option\nfn f(c: bool, v: i32) i32? { if c { return Some(v) } else { return null } }\nfn g(c: bool, v: i32) i32? { return if c { Some(v) } else { null } }\n",
        ],
        ["core.option", "branch_join"],
    )
    assert_true(errors == 0, "a `Some` branch and a `null` branch settle on `Option(T)`")
}

test "a bare value branch does not implicitly wrap into an optional" {
    let errors = count_check_errors(
        [
            OPTION_SRC,
            "import core.option\nfn f(c: bool, v: i32) i32? { if c { return v } else { return null } }\n",
        ],
        ["core.option", "branch_bare"],
    )
    assert_true(errors > 0, "return of bare `T` against `T?` is an error")
}

test "unary operators type from their operand, not a fresh var" {
    // `-x` on f64 must record f64 - the fresh-var fallback made lowering emit integer negation over
    // a double (docs/known-issues.md). The wrong-result-type variants prove the node carries the
    // operand's type rather than an unconstrained var that unifies with anything.
    let errors = count_check_errors(
        [
            "fn f(x: f64) f64 { return -x }\nfn g(x: u32) u32 { return ~x }\nfn h(b: bool) bool { return !b }\n",
        ],
        ["unary_ok"],
    )
    assert_true(errors == 0, "neg/bitnot/not over matching operand types check clean")

    let neg_errors = count_check_errors(["fn f(x: f64) i32 { return -x }\n"], ["unary_neg_ty"])
    assert_true(neg_errors > 0, "`-f64` returned as i32 is a mismatch, not a silent fresh var")
}

test "logical not requires a bool operand" {
    let errors = count_check_errors(["fn f(x: i32) bool { return !x }\n"], ["unary_not_i32"])
    assert_true(errors > 0, "`!` over i32 is rejected")
}

// M8: `??` and `?`.

test "coalesce unwraps or chains by the right operand's shape" {
    let errors = count_check_errors(
        [
            OPTION_SRC,
            "import core.option\nfn f(o: i32?, d: i32) i32 { return o ?? d }\nfn g(a: i32?, b: i32?) i32? { return a ?? b }\n",
        ],
        ["core.option", "coalesce_ok"],
    )
    assert_true(errors == 0, "Option(T) ?? T and Option(T) ?? Option(T) both check clean")
}

test "coalesce rejects a mismatched fallback and a non-Option left side" {
    let mismatch = count_check_errors(
        [OPTION_SRC, "import core.option\nfn f(o: i32?, d: f64) i32 { return o ?? d }\n"],
        ["core.option", "coalesce_bad_rhs"],
    )
    assert_true(mismatch > 0, "f64 fallback against Option(i32) is a mismatch")

    let bare = count_check_errors(
        [OPTION_SRC, "import core.option\nfn g(x: i32) i32 { return x ?? 0 }\n"],
        ["core.option", "coalesce_bad_lhs"],
    )
    assert_true(bare > 0, "`??` over a non-Option left side is rejected")
}

// The `?` fixtures register the real well-known modules: `core.try` for `TryResult` and
// `core.option` for `Option` plus its `op_try`, copied from the stdlib.
const TRY_SRC: String = "pub type TryResult = enum(T, R) {\n    Continue(T),\n    Return(R),\n}\n"
const OPTION_TRY_SRC: String = "import core.try\npub type Option = enum(T) {\n    None,\n    Some(T),\n}\npub fn op_try(self: move Option($T)) TryResult(T, Option($U)) {\n    return self match {\n        Some(v) => TryResult.Continue(move v),\n        None => TryResult.Return(None),\n    }\n}\n"

test "postfix ? types as the Continue payload and constrains the return" {
    let errors = count_check_errors(
        [
            TRY_SRC,
            OPTION_TRY_SRC,
            "import core.option\nfn f(o: i32?) i32? { let v = o? return Some(v + 1) }\n",
        ],
        ["core.try", "core.option", "try_ok"],
    )
    assert_true(errors == 0, "`o?` continues with i32 inside a fn returning i32?")
}

test "postfix ? in a function with an incompatible return is rejected" {
    let errors = count_check_errors(
        [
            TRY_SRC,
            OPTION_TRY_SRC,
            "import core.option\nfn f(o: i32?) i32 { let v = o? return v }\n",
        ],
        ["core.try", "core.option", "try_bad_ret"],
    )
    assert_true(errors > 0, "the early-returned Option cannot fit a bare i32 return")
}

test "postfix ? without an op_try overload is E2092" {
    let errors = count_check_errors(
        [
            TRY_SRC,
            OPTION_TRY_SRC,
            "import core.option\ntype Plain = struct { v: i32 }\nfn f(p: Plain) i32 { let v = p? return v }\n",
        ],
        ["core.try", "core.option", "try_none"],
    )
    assert_true(errors > 0, "`?` on a type with no op_try is rejected")
}

// M9: interpolation desugars to StringBuilder calls (RFC-004).

// Minimal StringBuilder surface the desugar resolves against. `Owned` stands in for OwnedString -
// the desugar hardcodes no type, it takes whatever `to_string` returns. A hole naming a place is
// read through `writer` and `format`, so the surface carries both.
const INTERP_SB_SRC: String = "import core.string\nimport core.option\npub type StringBuilder = struct { n: usize }\npub type Owned = struct { n: usize }\npub fn string_builder(capacity: usize, allocator: &StringBuilder? = null) StringBuilder { return StringBuilder { n = capacity } }\npub fn append(sb: &StringBuilder, text: String) { sb.n = sb.n + text.len }\npub fn append(sb: &StringBuilder, v: i32) { sb.n = sb.n + 1 }\npub fn append(sb: &StringBuilder, v: i32, spec: String) { sb.n = sb.n + spec.len }\npub fn writer(sb: &StringBuilder) &StringBuilder { return sb }\npub fn format(v: i32, w: &StringBuilder, spec: String) { w.n = w.n + 1 }\npub fn to_string(sb: &StringBuilder) Owned { return Owned { n = sb.n } }\npub fn deinit(sb: &StringBuilder) {}\npub fn deinit(s: &Owned) {}\n"
const INTERP_STRING_SRC: String = "pub type String = struct { ptr: &u8, len: usize }\n"

test "interpolation desugars: appends resolve and the result is to_string's type" {
    let errors = count_check_errors(
        [
            OPTION_SRC,
            INTERP_STRING_SRC,
            INTERP_SB_SRC,
            "import std.string_builder\nfn f(x: i32) i32 { const s = $\"got {x} ok\" s.deinit() return x }\n",
        ],
        ["core.option", "core.string", "std.string_builder", "interp_ok"],
    )
    assert_true(
        errors == 0,
        "the segment appends and the hole's format resolve; the result takes Owned's UFCS surface",
    )

    let hole_errors = count_check_errors(
        [
            OPTION_SRC,
            INTERP_STRING_SRC,
            INTERP_SB_SRC,
            "import std.string_builder\nfn f() i32 { const s = $\"got {no_such_name}\" return 0 }\n",
        ],
        ["core.option", "core.string", "std.string_builder", "interp_bad_hole"],
    )
    assert_true(hole_errors > 0, "an unknown identifier inside a hole is reported")
}

test "into-builder interpolation appends onto the target and is void" {
    let errors = count_check_errors(
        [
            OPTION_SRC,
            INTERP_STRING_SRC,
            INTERP_SB_SRC,
            "import std.string_builder\nfn g(sb: &StringBuilder, x: i32) { $sb\"v={x}\" }\n",
        ],
        ["core.option", "core.string", "std.string_builder", "interp_into"],
    )
    assert_true(errors == 0, "the target's append overloads resolve; the statement is void")
}

test "a hole's format spec reaches format, and a place is read rather than appended" {
    let errors = count_check_errors(
        [
            OPTION_SRC,
            INTERP_STRING_SRC,
            INTERP_SB_SRC,
            "import std.string_builder\nfn f(x: i32) i32 { const s = $\"n={x:04}\" s.deinit() return x }\n",
        ],
        ["core.option", "core.string", "std.string_builder", "interp_spec"],
    )
    assert_true(errors == 0, "`{x:04}` resolves as x.format(sb.writer(), \"04\")")
}

// ── M10 - specialization ─────────────────────────────────────────────

// Check `srcs` and hand back the full result so tests can inspect the specialization list. Leaks
// like the driver does - one-shot.
fn check_result_of(srcs: String[], paths: String[]) TypeCheckResult {
    let mods = list(srcs.len)
    for i in 0..srcs.len {
        mods.push(parse_src(srcs[i], i as i32))
    }
    let ps = list(paths.len)
    ps.push_all(paths)
    let chk = checker()
    let gen_srcs: List(OwnedString) = list(0)
    let gen_fps: List(OwnedString) = list(paths.len)
    for i in 0..paths.len {
        gen_fps.push(from_view(paths[i]))
    }
    let gens = template_state()
    return check_all(&chk, &mods, &ps, &gen_srcs, &gen_fps, &gens)
}

test "every node id in the result names the span it came from" {
    let res = check_result_of(["fn f(x: i32) i32 { let y = x + 1\n return y }\n"], ["m"])
    assert_true(res.node_types.len() > 0 as usize, "the body checked")
    let unmapped: usize = 0
    for e in res.node_types {
        if res.get_span(e.key).is_none() {
            unmapped = unmapped + 1
        }
    }
    assert_eq(unmapped, 0 as usize, "no typed node is missing its span")
    res.deinit()
}

test "a recorded span round-trips to the id it was minted from" {
    let res = check_result_of(["fn f() i32 { return 7 }\n"], ["m"])
    let mismatched: usize = 0
    for e in res.spans {
        if node_id_of(e.value) != e.key {
            mismatched = mismatched + 1
        }
    }
    assert_eq(mismatched, 0 as usize, "every entry fingerprints back to its key")
    res.deinit()
}

test "the result names the file each id belongs to" {
    let res = check_result_of(
        ["pub fn g() i32 { return 1 }\n", "import a\nfn h() i32 { return g() }\n"],
        ["a", "b"],
    )
    assert_true(res.path_of(0i32).unwrap() == "a", "file 0 is the first module")
    assert_true(res.path_of(1i32).unwrap() == "b", "file 1 is the second")
    assert_true(res.path_of(2i32).is_none(), "past the end is unknown")
    // `none_span` (-1) and the checker's synthetic ids (-2) name no file.
    assert_true(res.path_of(-2i32).is_none(), "synthetic file ids are unknown")
    res.deinit()
}

test "struct fields and enum variants carry their declaration span" {
    let res = check_result_of(
        ["pub type P = struct { x: i32\ny: i32 }\npub type E = enum { A\nB(i32) }\n"],
        ["m"],
    )
    let fields_spanned: usize = 0
    let variants_spanned: usize = 0
    for i in 0..(res.nominals.next_id as usize) {
        let d = res.nominals.find(i as NominalId)
        if d.is_none() {
            continue
        }
        d.unwrap().* match {
            NomStruct(sd) => {
                for &f in sd.fields {
                    if !is_none(f.decl_span) {
                        fields_spanned = fields_spanned + 1
                    }
                }
            }
            NomEnum(ed) => {
                for &v in ed.variants {
                    if !is_none(v.decl_span) {
                        variants_spanned = variants_spanned + 1
                    }
                }
            }
        }
    }
    assert_eq(fields_spanned, 2 as usize, "both fields of P point at their declaration")
    assert_eq(variants_spanned, 2 as usize, "both variants of E point at theirs")
    res.deinit()
}

test "a generic call instantiates once per concrete signature" {
    let res = check_result_of(
        [
            "pub fn id(x: $T) T { return x }\nfn main() i32 { let a = id(1) let b = id(2) let c = id(true) if c { return a } return b }\n",
        ],
        ["m"],
    )
    // Two i32 calls share one specialization; the bool call adds one.
    assert_eq(res.specializations.len(), 2 as usize, "two concrete signatures, two specializations")
    let s0 = res.specializations.get(0 as u32)
    assert_eq(s0.concrete_params.len, 1 as usize, "id takes one param")
    assert_true(s0.name == "id", "specialization names the template")
    // The instantiated bodies were re-checked: their overlays carry node types for the template
    // body's nodes.
    assert_true(s0.overlay.node_types.length > 0, "overlay recorded body node types")
}

test "structural specificity outranks quantifier count in overload ranking" {
    // `pick(Pair($A,$B))` quantifies MORE vars (2) than the catch-all `pick($T)` (1), but its
    // receiver carries a concrete constructor, so it must win. The overloads' return types differ
    // (i32 vs bool): if the catch-all wins, `main` returns bool from an i32 function and
    // the check errors — 0 errors proves the structured overload won.
    let errs = count_check_errors(
        [
            "pub type Pair = struct(A, B) { a: A b: B }\npub fn pick(x: Pair($A, $B)) i32 { return 1 }\npub fn pick(x: $T) bool { return true }\nfn main() i32 { let p: Pair(i32, u8) p.a = 1i32 p.b = 2u8 return pick(p) }\n",
        ],
        ["m"],
    )
    assert_eq(errs, 0 as usize, "the structured overload wins despite more quantified vars")
}

// =============================================================================
// Overload ranking: given the signatures in scope, which one a call resolves to
// =============================================================================

// What one call resolved to: the winner's declared type rendered with nominal names (`fn(&Inner)
// i64`; a type parameter renders as `?N`) and the `op_deref` chain length recorded on the call for
// lowering.
type ResolvedCall = struct {
    signature: OwnedString
    hops: usize
}

// Check `src` as module `m` and report the overload its one call to `callee` resolved to - a
// spelled call (`resolved_targets`) or a protocol operator such as `op_index_ref` or `iter`
// (`resolved_ops`). A generic winner is read back through its specialization.
fn resolved_call(src: String, callee: String) ResolvedCall {
    let res = check_result_of([src], ["m"])
    defer res.deinit()
    let sb = string_builder(64)
    let hops = 0usize
    for e in res.resolved_targets {
        let fid: u32? = e.value match {
            RtFunction(id) => Some(id)
            RtSpecialized(sid) => Some(res.specializations.get(sid).function_id)
            _ => null
        }
        if fid.is_some() {
            note_resolved(&res, e.key, fid.unwrap(), callee, &sb, &hops)
        }
    }
    for o in res.resolved_ops {
        let fid = o.value.spec_id match {
            Some(sid) => res.specializations.get(sid).function_id
            None => o.value.function_id
        }
        note_resolved(&res, o.key, fid, callee, &sb, &hops)
    }
    return .{ signature = sb.to_string(), hops = hops }
}

// Render `fid`'s signature into `sb` and read the hop chain on `node` when `fid` is `callee`.
fn note_resolved(
    res: &TypeCheckResult,
    node: NodeId,
    fid: u32,
    callee: String,
    sb: &StringBuilder,
    hops: &usize,
) {
    let scheme = res.functions.find_by_id(fid)
    if scheme.is_none() or scheme.unwrap().name != callee {
        return
    }
    format_with_names(&res.interner, scheme.unwrap().signature.body, sb, Some(&res.nominals))
    let chain = res.receiver_derefs.get_ref(node)
    if chain.is_some() {
        const __chain_v = chain.unwrap()
        hops.* = __chain_v.len
    }
}

// `Inner`, and `Wrap` reaching it through `op_deref`, in front of `rest`.
fn with_wrap(rest: String) OwnedString {
    let sb = string_builder(256)
    sb.append("pub type Inner = struct { value: i64 }\n")
    sb.append("pub type Wrap = struct { pad: i64 inner: Inner }\n")
    sb.append("pub fn op_deref(w: &Wrap) &Inner { return &w.inner }\n")
    sb.append(rest)
    return sb.to_string()
}

test "ranking: a concrete parameter beats a catch-all on a direct call" {
    let src = with_wrap(
        "pub fn f(x: Inner) i64 { return 1 }\npub fn f(x: $T) i64 { return 2 }\nfn main() i64 { let i: Inner return f(i) }\n",
    )
    defer src.deinit()
    let r = resolved_call(src.view, "f")
    defer r.signature.deinit()
    assert_true(r.signature.view == "fn(Inner) i64", "the nominal parameter is the stricter match")
}

test "ranking: a value receiver as written beats adapting it to a reference parameter" {
    let src = with_wrap(
        "pub fn f(x: &Inner) i64 { return 1 }\npub fn f(x: $T) i64 { return 2 }\nfn main(i: Inner) i64 { return i.f() }\n",
    )
    defer src.deinit()
    let r = resolved_call(src.view, "f")
    defer r.signature.deinit()
    assert_true(r.signature.view.starts_with("fn(?"), "the receiver as written takes the call")
    assert_eq(r.hops, 0 as usize, "no op_deref hop")
}

test "ranking: a value receiver adapts to a reference parameter when nothing takes it as written" {
    let src = with_wrap(
        "pub fn f(x: &Inner) i64 { return 1 }\nfn main(i: Inner) i64 { return i.f() }\n",
    )
    defer src.deinit()
    let r = resolved_call(src.view, "f")
    defer r.signature.deinit()
    assert_true(r.signature.view == "fn(&Inner) i64", "the adapted receiver takes the call")
    assert_eq(r.hops, 0 as usize, "no op_deref hop")
}

test "ranking: a direct hit beats an equally specific overload through op_deref" {
    let src = with_wrap(
        "pub fn f(x: &Wrap) i64 { return 1 }\npub fn f(x: &Inner) i64 { return 2 }\nfn main(w: &Wrap) i64 { return w.f() }\n",
    )
    defer src.deinit()
    let r = resolved_call(src.view, "f")
    defer r.signature.deinit()
    assert_true(r.signature.view == "fn(&Wrap) i64", "the wrapper's own overload wins")
    assert_eq(r.hops, 0 as usize, "no op_deref hop")
}

test "ranking: a catch-all matched as written beats a concrete overload through op_deref" {
    let src = with_wrap(
        "pub fn f(x: &Inner) i64 { return 1 }\npub fn f(x: $I) i64 { return 2 }\nfn main(w: &Wrap) i64 { return w.f() }\n",
    )
    defer src.deinit()
    let r = resolved_call(src.view, "f")
    defer r.signature.deinit()
    assert_true(r.signature.view.starts_with("fn(?"), "the receiver as written takes the call")
    assert_eq(r.hops, 0 as usize, "no op_deref hop")
}

test "ranking: the peel also runs through a generic wrapper" {
    let src = with_wrap(
        "pub type Box = struct(T) { pad: i64 inner: T }\npub fn op_deref(b: &Box($T)) &T { return &b.inner }\npub fn f(x: &Inner) i64 { return 1 }\nfn main(b: &Box(Inner)) i64 { return b.f() }\n",
    )
    defer src.deinit()
    let r = resolved_call(src.view, "f")
    defer r.signature.deinit()
    assert_true(r.signature.view == "fn(&Inner) i64", "the peeled receiver's overload wins")
    assert_eq(r.hops, 1 as usize, "one op_deref hop recorded for lowering")
}

test "ranking: the peel chains through two wrappers" {
    let src = with_wrap(
        "pub type Outer = struct { tag: i64 w: Wrap }\npub fn op_deref(o: &Outer) &Wrap { return &o.w }\npub fn f(x: &Inner) i64 { return 1 }\nfn main(o: &Outer) i64 { return o.f() }\n",
    )
    defer src.deinit()
    let r = resolved_call(src.view, "f")
    defer r.signature.deinit()
    assert_true(r.signature.view == "fn(&Inner) i64", "the innermost receiver's overload wins")
    assert_eq(r.hops, 2 as usize, "both hops recorded for lowering")
}

test "ranking: a wrapper declares the member a catch-all would otherwise take" {
    // The `Dict.any(fn(k, v) ...)` shape: std.iter's `any($I, $F)` matches the wrapper as written,
    // so the wrapper declares its own `any` rather than relying on the peel.
    let src = with_wrap(
        "pub fn any(x: &Inner, pred: $F) bool { return pred(x.value, x.value) }\npub fn any(w: &Wrap, pred: $F) bool { return w.inner.any(pred) }\npub fn any(it: $I, pred: $F) bool { return pred(0i64) }\nfn main(w: &Wrap) bool { return w.any(fn(a, b) { a == b }) }\n",
    )
    defer src.deinit()
    let r = resolved_call(src.view, "any")
    defer r.signature.deinit()
    assert_true(r.signature.view.starts_with("fn(&Wrap, "), "the wrapper's own overload wins")
    assert_eq(r.hops, 0 as usize, "no op_deref hop")
}

test "ranking: indexing resolves op_index_ref through op_deref, like the call it desugars to" {
    let src = with_wrap(
        "pub fn op_index_ref(x: &Inner, i: usize) &i64 { return &x.value }\nfn main(w: &Wrap) i64 { return w[0usize] }\n",
    )
    defer src.deinit()
    let r = resolved_call(src.view, "op_index_ref")
    defer r.signature.deinit()
    assert_true(r.signature.view == "fn(&Inner, usize) &i64", "the inner type's operator")
    assert_eq(r.hops, 1 as usize, "one op_deref hop recorded on the index node")
}

test "ranking: for resolves iter through op_deref, like the call it desugars to" {
    let src = with_wrap(
        "pub type It = struct { n: i64 }\npub fn iter(x: &Inner) It { return It { n = x.value } }\npub fn next(it: &It) i64? { if it.n == 0 { return null } it.n = it.n - 1 return Some(it.n) }\nfn main(w: &Wrap) i64 { let t = 0i64 for x in w { t = t + x } return t }\n",
    )
    defer src.deinit()
    let r = resolved_call(src.view, "iter")
    defer r.signature.deinit()
    assert_true(r.signature.view == "fn(&Inner) It", "the inner type's iter")
    assert_eq(r.hops, 1 as usize, "one op_deref hop recorded beside the iter pick")
}

test "ranking: the catch-all still wins when nothing through the peel matches" {
    let src = with_wrap(
        "pub type Other = struct { n: i64 }\npub fn f(x: &Other) i64 { return 1 }\npub fn f(x: $I) i64 { return 2 }\nfn main(w: &Wrap) i64 { return w.f() }\n",
    )
    defer src.deinit()
    let r = resolved_call(src.view, "f")
    defer r.signature.deinit()
    assert_true(r.signature.view.starts_with("fn(?"), "only the catch-all matches")
    assert_eq(r.hops, 0 as usize, "no op_deref hop")
}

test "generic template bodies only report when instantiated" {
    // `bad`'s body calls a function that does not exist - uninstantiated the template is never
    // validated, instantiated it reports.
    let silent = count_check_errors(["pub fn bad(x: $T) T { return no_such_fn(x) }\n"], ["m"])
    assert_true(silent == 0, "an uninstantiated template is never validated")

    let loud = count_check_errors(
        ["pub fn bad(x: $T) T { return no_such_fn(x) }\nfn main() i32 { return bad(1) }\n"],
        ["m"],
    )
    assert_true(loud > 0, "instantiating the template surfaces its body errors")
}

test "a nested generic call specializes transitively" {
    let res = check_result_of(
        [
            "pub fn inner(x: $T) T { return x }\npub fn outer(x: $T) T { return inner(x) }\nfn main() i32 { return outer(7) }\n",
        ],
        ["m"],
    )
    // outer(i32) instantiates, and its body's inner(x) pick drains into inner(i32).
    assert_eq(res.specializations.len(), 2 as usize, "outer and inner both specialize")
}

test "a self-recursive generic reuses its own specialization" {
    let res = check_result_of(
        [
            "pub fn rec(x: $T, n: i32) T { if n > 0 { return rec(x, n - 1) } return x }\nfn main() i32 { return rec(3, 2) }\n",
        ],
        ["m"],
    )
    assert_eq(
        res.specializations.len(),
        1 as usize,
        "recursion hits the registered key, no second entry",
    )
}
test "a generic member call inside a partially-fixed generic instantiates" {
    // Regression: `set2(self: &D(Key, $V), ...)` is generic only through a NESTED type argument. A
    // broken `declares_generic` walked this as concrete, phase 3 checked the template with V
    // unbound, and the stray pick could never infer `cap`'s type arguments.
    let errors = count_check_errors(
        [
            "type Key = struct { n: usize }\ntype D = struct(K, V) { n: usize\n    k: K\n    v: V\n}\nfn cap(self: &D($K, $V)) usize { return self.n }\nfn set2(self: &D(Key, $V), value: V) usize { return self.cap() }\nfn main() i32 {\n    let d: D(Key, i32) = D(Key, i32) { n = 0usize, k = Key { n = 1usize }, v = 3i32 }\n    const c = d.set2(5i32)\n    return 0\n}\n",
        ],
        ["m"],
    )
    assert_true(errors == 0, "cap's K and V pin from set2's concrete receiver")
}

// ─────────────────────────────────────────────────────────────────────
// Lambda / closure tests (RFC-014)
// ─────────────────────────────────────────────────────────────────────

test "a non-capturing lambda records a bare-fn lambda info" {
    let src = "fn apply(f: fn(i32) i32, x: i32) i32 { return f(x) }\nfn main() i32 { return apply(fn(v: i32) i32 { v + 1 }, 4) }\n"
    let errs = count_check_errors([src], ["m"])
    assert_eq(errs, 0 as usize, "checks clean")
    let res = check_result_of([src], ["m"])
    assert_eq(res.lambdas.len(), 1 as usize, "one lambda record")
    assert_eq(res.closures.len(), 0 as usize, "no captures, no closure table entry")
    for e in res.lambdas {
        assert_eq(e.value.captures.len, 0 as usize, "no captures")
        assert_eq(e.value.params.len, 1 as usize, "one parameter")
        assert_true(e.value.closure_id.is_none(), "no closure nominal")
    }
    res.deinit()
}

test "a capturing lambda synthesizes a closure and dispatches through $F" {
    let src = "fn apply(f: $F, x: i32) i32 where F: fn(i32) i32 { return f(x) }\nfn main() i32 { let k = 40 return apply(fn(v: i32) i32 { v + k }, 2) }\n"
    let errs = count_check_errors([src], ["m"])
    assert_eq(errs, 0 as usize, "capturing closure through $F checks clean")
    let res = check_result_of([src], ["m"])
    assert_eq(res.closures.len(), 1 as usize, "one closure dispatch entry")
    assert_eq(res.lambdas.len(), 1 as usize, "one lambda record")
    for e in res.lambdas {
        assert_eq(e.value.captures.len, 1 as usize, "captured k")
        assert_true(e.value.closure_id.is_some(), "closure nominal synthesized")
        assert_true(e.value.captures[0].name == "k", "capture is by name")
    }
    res.deinit()
}

test "unannotated lambda params pin through a generic callable slot" {
    let src = "fn apply(f: $F, x: i32) i32 where F: fn(i32) i32 { return f(x) }\nfn main() i32 { return apply(fn(v) { v + 1 }, 4) }\n"
    let errs = count_check_errors([src], ["m"])
    assert_eq(errs, 0 as usize, "no-annotation lambda through $F checks clean")
    let res = check_result_of([src], ["m"])
    for e in res.lambdas {
        // The instantiation's body re-check unified the fresh param var with i32; the zonked record
        // must be concrete.
        assert_eq(
            e.value.params[0],
            prim_of(PrimitiveKind.I32),
            "param pinned to i32 through the instantiation",
        )
    }
    res.deinit()
}

test "a closure may assign a captured name (RFC-033)" {
    let errs = count_check_errors(
        [
            "fn take(f: $F) i32 where F: fn(i32) i32 { return f(1) }\nfn main() i32 { let k: i32 = 1\n return take(fn(v: i32) i32 { k = 2\n return v }) + k }\n",
        ],
        ["m"],
    )
    assert_eq(errs, 0 as usize, "captures are by reference")
}

// `&move` slots (RFC-033). Declarable in `core` alone, so these check through a core-named module.

test "a core module may take from a slot when it refills it" {
    let errs = count_check_errors(
        [
            "type H = struct { owned fd: i32 }
pub fn exchange(a: &move H, b: &move H) { let tmp = move a.*
 a.* = move b.*
 b.* = move tmp }
",
        ],
        ["core.slots"],
    )
    assert_eq(errs, 0 as usize, "the take is paired with a refill on the only exit")
}

test "a slot left empty is refused" {
    let errs = count_check_errors(
        ["type H = struct { owned fd: i32 }
pub fn take(a: &move H) H { return move a.* }
"],
        ["core.slots"],
    )
    assert_true(errs > 0, "the value left and none was put back (E2137)")
}

test "a slot emptied on one branch only is refused" {
    let errs = count_check_errors(
        [
            "type H = struct { owned fd: i32 }
pub fn maybe(a: &move H, b: move H, c: bool) H { let tmp = move a.*
 if c { a.* = move b
 return tmp }
 return tmp }
",
        ],
        ["core.slots"],
    )
    assert_true(errs > 0, "the branch that returns without refilling is reported")
}

test "a nested closure captures through the enclosing one (RFC-033)" {
    let errs = count_check_errors(
        [
            "fn take(f: $F) i32 where F: fn(i32) i32 { return f(1) }\nfn main() i32 { let a: i32 = 1\n return take(fn(x: i32) i32 { let g = fn(y: i32) i32 { return y + a }\n return g(x) + a }) }\n",
        ],
        ["m"],
    )
    assert_eq(errs, 0 as usize, "transitive captures check")
}

test "a capturing closure cannot fill a bare fn slot (E2111 hint)" {
    let errs = count_check_errors(
        [
            "fn apply(f: fn(i32) i32, x: i32) i32 { return f(x) }\nfn main() i32 { let k = 1\n return apply(fn(v: i32) i32 { v + k }, 2) }\n",
        ],
        ["m"],
    )
    assert_true(errs > 0, "closure into fn slot reports")
}

test "a lambda inside a generic template records per instantiation" {
    let src = "fn scale(x: $T) T where T: copyable { let f = fn(v: T) T { v }\n return f(x) }\nfn main() i32 { let a = scale(1i32)\n let b = scale(2i64)\n if b == 2 { return a } return 0 }\n"
    let errs = count_check_errors([src], ["m"])
    assert_eq(errs, 0 as usize, "template lambda checks per instantiation")
    let res = check_result_of([src], ["m"])
    // The lambda lives in the template body: each instantiation's overlay carries its own record;
    // the program table has none.
    assert_eq(res.lambdas.len(), 0 as usize, "no program-table record")
    let seen: usize = 0
    for i in 0..(res.specializations.next_id as usize) {
        let sp = res.specializations.find(i as u32)
        if sp.is_none() {
            continue
        }
        let sr = sp.unwrap()
        seen = seen + sr.overlay.lambdas.len()
    }
    assert_eq(seen, 2 as usize, "one lambda record per instantiation")
    res.deinit()
}
