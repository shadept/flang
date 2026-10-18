// InferenceResults - mutable accumulator the checker fills in.
//
// Three primary side tables, all keyed by `NodeId`:
//
//   - `node_types`      every expression / pattern / type-expr node's
//                       final resolved type. Coerced types land here
//                       *before the engine is discarded* - lowering
//                       reads this dict and never inspects the slot.
//
//   - `resolved_ops`    resolved operator binding for each operator
//                       node (the function the `+`, `==`, `[]`, …
//                       desugared to). Null entries mean "no overload
//                       - primitive IR instruction".
//
//   - `resolved_targets` resolved function / variant / field / local
//                       declaration that each name reference points
//                       to. Used by find-references and codegen.
//
// Plus auxiliary state: monomorphisation outputs and unsuffixed literal book-keeping the checker
// drains in a post-inference pass.

import std.allocator
import std.collections.dict
import std.collections.list
import std.option
import std.string

import flang_core.span
import flang_parser.ast

import flang_typer.node_id
import flang_typer.type

// Where a name reference points to. Distinguishing variants drives `goto-definition` resolution +
// lets the lowering pass pick the right code path.
pub type ResolvedTarget = enum {
    RtFunction(u32) // FunctionRegistry id
    RtLocal(NodeId) // declaration node
    // A type binding's declaration node, on a type-position use: a type parameter (`$T`, a list
    // entry), `Self`, an associated type (RFC-036).
    RtType(NodeId)
    RtStructField(NominalId, u32) // nominal + field index
    RtEnumVariant(NominalId, u32) // nominal + variant index
    RtSpecialized(SpecId) // SpecializationRegistry id
    // Module-level constant, by FQN (M11 globals). The view is interned into the result's
    // `synth_strings`, so it outlives the checker. Recorded on every const READ node and on the
    // ConstDecl node itself (lowering's pre-pass reads the decl's own entry to name its global).
    RtConst(String)
    // Runtime context field (RFC-038), by FQN, interned like `RtConst`. Recorded on every `ctx.f`
    // read and on every rebind's `f = v` argument.
    RtContextField(String)
}

// Resolved operator dispatch. `function_id` indexes the function registry. `negate_result` and
// `cmp_derived_op` capture the derived- operator dispatch the C# checker uses for `!=` / `<` / `>=`
// (where you only define `==` and `<` and the others come for free).
pub type ResolvedOperator = struct {
    function_id: u32
    negate_result: bool
    // null when the operator is not derived from a comparison.
    cmp_derived_op: BinaryOpDerived?
    is_ref_form: bool
    // When the picked operator function is generic, the specialization the call site instantiated
    // (M10). Lowering calls the specialization's symbol; `function_id` then names the template.
    spec_id: SpecId?
    // A binary operator's operands reached through `op_deref`: how many hops each side took. The
    // hops sit on the operator node's deref chain, the left operand's first.
    lhs_hops: u32
    rhs_hops: u32
}

pub type BinaryOpDerived = enum {
    BodEq
    BodNe
    BodLt
    BodLe
    BodGt
    BodGe
}

// One capture of a checked lambda: the outer binding's name, its declaration node and its
// (eventually zonked) type. Captures are by reference (RFC-033); `ty` is the binding's type, the
// closure struct's field holds `&ty`.
pub type CaptureRec = struct {
    name: String
    decl: NodeId
    ty: Ty
}

// One checked lambda literal, keyed by the LambdaExpr's node id in `InferenceResults.lambdas`.
// Overlay-scoped on purpose: a lambda inside a generic template gets one record - with its own
// types, captures, and symbol - per instantiation. Empty `captures` = bare function pointer;
// otherwise `closure_id` names the synthesized capture struct and `symbol` its `op_call` function.
pub type LambdaInfo = struct {
    span: SourceSpan
    params: List(Ty)
    // The `move` bit of each parameter, as written or taken from the slot the lambda fills.
    moves: usize
    ret: Ty
    captures: List(CaptureRec)
    closure_id: NominalId?
    symbol: OwnedString
    // `ConvC` for a lambda filling a `#foreign fn` slot: its body is a C function.
    conv: FnConv
}

pub fn deinit(self: move LambdaInfo) {
    self.params.deinit()
    self.captures.deinit()
    self.symbol.deinit()
}

// Global (not overlay-scoped) closure dispatch record: how to call a value whose type is the
// synthesized closure nominal. Keyed by NominalId in `Checker.closures` /
// `TypeCheckResult.closures` so a closure that traveled through a `$F` slot dispatches from any
// body. `params` excludes the `self` env pointer.
pub type ClosureSig = struct {
    params: List(Ty)
    moves: usize
    ret: Ty
    symbol: OwnedString
    lambda_node: NodeId
}

pub fn deinit(self: move ClosureSig) {
    self.params.deinit()
    self.symbol.deinit()
}

pub type InferenceResults = struct {
    // Values are interned handles (RFC-024): the checker's interner maps one back to a tree. A live
    // entry may cite variables; the final zonk re-interns every entry with the variables resolved.
    node_types: Dict(NodeId, Ty)
    resolved_ops: Dict(NodeId, ResolvedOperator)
    resolved_targets: Dict(NodeId, ResolvedTarget)
    // Types used as `Type(T)` values (RTTI). Pre-zonked when the checker finishes; consumed by
    // codegen to emit the runtime type-info table.
    instantiated_types: List(Ty)
    // Owned backing buffers for checker-synthesized names and literal texts (interpolation's
    // builder locals, re-escaped segment text). The synthesized AST in `desugars` references them
    // as views, so they live and die with this result set.
    synth_strings: List(OwnedString)
    // Checker-synthesized AST keyed by the node it replaces - today only interpolation's
    // StringBuilder desugar (RFC-004). Lowering lowers the stored block instead of the original
    // node. The blocks are checker-allocated and share the result's lifetime.
    desugars: Dict(NodeId, &BlockExpr)
    // Checked lambda literals (RFC-014), keyed by the LambdaExpr node. Lives in the result set -
    // not a global table - so a lambda inside a generic template records once per instantiation
    // overlay.
    lambdas: Dict(NodeId, LambdaInfo)
    // M11: per call site, the callee's default expressions for the parameters the call omitted, in
    // parameter order. The exprs are shallow copies of the callee declaration's AST (shared
    // children), checked at the call site so their node types land in this result set. Lowering
    // appends them after the explicit arguments. A call with no entry here that is short of the
    // callee's arity refuses.
    default_args: Dict(NodeId, List(&Expr))
    // M12: per call site, the COMPLETE argument list in parameter order, excluding a UFCS receiver.
    // Recorded when the AST's own argument order is not the call's argument order - a
    // named-argument call (names select their parameters) or a variadic call (the surplus arguments
    // are packed into one synthesized array literal). Lowering emits this list verbatim in place of
    // `call.args`; a call that needs one and has no entry refuses.
    arg_lists: Dict(NodeId, List(&Expr))
    // A UFCS call whose receiver resolved through `op_deref` hops (checker's `deref_retry`), keyed
    // by the call node: the op_deref pick per hop, outermost first. Lowering calls each hop on the
    // receiver's address and passes the last hop's result as the receiver argument. Generic hops
    // are rewritten to their specializations by the M10 drain, like `resolved_targets`.
    receiver_derefs: Dict(NodeId, List(ResolvedTarget))
    // A UFCS call whose receiver took the winner's first parameter adapted between value and
    // reference (spec 7.2), keyed by the call node. A call with no entry passes its receiver as
    // written. Lowering reads this rather than comparing types: a receiver whose type was still
    // open at the call is bound to the parameter's shape, so its type cannot tell the two apart.
    receiver_adapts: Dict(NodeId, ReceiverAdapt)
    // An ARGUMENT that reached its parameter through `op_deref` (RFC-020), keyed by the argument's
    // own node: the pick per hop, outermost first. Separate from `receiver_derefs` because a node
    // can be both - `f(xs[i])` records the index receiver's chain on the same `xs[i]` node.
    arg_derefs: Dict(NodeId, List(ResolvedTarget))
    // Inverse of `node_id.node_id_of`: the span every minted id was fingerprinted from. The
    // fingerprint clamps a span longer than 64 KB or a file past 65535, so this table is the only
    // exact mapping back.
    spans: Dict(NodeId, SourceSpan)

    // Key capture (RFC-022 5d). While `cap_on`, every record_* call appends its key to the matching
    // list, so a module's slot can note WHICH entries it wrote and harvest their final values once
    // the demand has settled. Keys only - values are read back from the finished tables, where
    // coercion overwrites and drain rewrites have already landed. An overlay result set never
    // captures: instantiations swap in a fresh `InferenceResults`, whose flag is off.
    cap_on: bool
    cap_spans: List(NodeId)
    cap_types: List(NodeId)
    cap_targets: List(NodeId)
    cap_ops: List(NodeId)
    cap_desugars: List(NodeId)
    cap_lambdas: List(NodeId)
    cap_default_args: List(NodeId)
    cap_arg_lists: List(NodeId)
    cap_derefs: List(NodeId)
    cap_arg_derefs: List(NodeId)
    cap_adapts: List(NodeId)
}

// How a UFCS receiver was adapted to its parameter.
pub type ReceiverAdapt = enum {
    // A value taken by a `&T` parameter: the callee gets its address, a temporary's spilled slot.
    ByRef
    // A reference taken by a value parameter: the callee gets the value it points to.
    ByValue
}

// The keys one capture window collected, moved out by `end_capture`.
pub type CapturedKeys = struct {
    spans: List(NodeId)
    types: List(NodeId)
    targets: List(NodeId)
    ops: List(NodeId)
    desugars: List(NodeId)
    lambdas: List(NodeId)
    default_args: List(NodeId)
    arg_lists: List(NodeId)
    derefs: List(NodeId)
    arg_derefs: List(NodeId)
    adapts: List(NodeId)
}

pub fn captured_keys() CapturedKeys {
    return .{
        spans = list(0),
        types = list(0),
        targets = list(0),
        ops = list(0),
        desugars = list(0),
        lambdas = list(0),
        default_args = list(0),
        arg_lists = list(0),
        derefs = list(0),
        arg_derefs = list(0),
        adapts = list(0),
    }
}

pub fn deinit(self: move CapturedKeys) {
    self.spans.deinit()
    self.types.deinit()
    self.targets.deinit()
    self.ops.deinit()
    self.desugars.deinit()
    self.lambdas.deinit()
    self.default_args.deinit()
    self.arg_lists.deinit()
    self.derefs.deinit()
    self.arg_derefs.deinit()
    self.adapts.deinit()
}

pub fn inference_results() InferenceResults {
    return .{
        node_types = dict(),
        resolved_ops = dict(),
        resolved_targets = dict(),
        instantiated_types = list(0),
        synth_strings = list(0),
        desugars = dict(),
        lambdas = dict(),
        default_args = dict(),
        arg_lists = dict(),
        receiver_derefs = dict(),
        receiver_adapts = dict(),
        arg_derefs = dict(),
        spans = dict(),
        cap_on = false,
        cap_spans = list(0),
        cap_types = list(0),
        cap_targets = list(0),
        cap_ops = list(0),
        cap_desugars = list(0),
        cap_lambdas = list(0),
        cap_default_args = list(0),
        cap_arg_lists = list(0),
        cap_derefs = list(0),
        cap_arg_derefs = list(0),
        cap_adapts = list(0),
    }
}

// Final table sizes of a finished result. A re-demand rewrites nearly every entry - replayed facts
// plus the re-run modules - so starting the next demand's tables at these sizes skips every
// doubling rehash on the replay path.
pub type TableCaps = struct {
    node_types: usize
    spans: usize
    targets: usize
    ops: usize
    desugars: usize
    lambdas: usize
    default_args: usize
    arg_lists: usize
    derefs: usize
    arg_derefs: usize
    adapts: usize
}

// Rebuild the node-keyed tables at the given capacities. Only meaningful on a fresh, empty result
// set - existing entries are dropped, not migrated.
pub fn presize_tables(self: &InferenceResults, s: &TableCaps) {
    install(&self.node_types, dict(s.node_types))
    install(&self.spans, dict(s.spans))
    install(&self.resolved_targets, dict(s.targets))
    install(&self.resolved_ops, dict(s.ops))
    install(&self.desugars, dict(s.desugars))
    install(&self.lambdas, dict(s.lambdas))
    install(&self.default_args, dict(s.default_args))
    install(&self.arg_lists, dict(s.arg_lists))
    install(&self.receiver_derefs, dict(s.derefs))
    install(&self.arg_derefs, dict(s.arg_derefs))
    install(&self.receiver_adapts, dict(s.adapts))
}

// Start collecting the keys of every entry recorded from here on.
pub fn begin_capture(self: &InferenceResults) {
    self.cap_on = true
}

// Stop collecting and hand the window's keys over, leaving the lists empty for the next window.
pub fn end_capture(self: &InferenceResults) CapturedKeys {
    self.cap_on = false
    let out = CapturedKeys {
        spans = replace(&self.cap_spans, list(0)),
        types = replace(&self.cap_types, list(0)),
        targets = replace(&self.cap_targets, list(0)),
        ops = replace(&self.cap_ops, list(0)),
        desugars = replace(&self.cap_desugars, list(0)),
        lambdas = replace(&self.cap_lambdas, list(0)),
        default_args = replace(&self.cap_default_args, list(0)),
        arg_lists = replace(&self.cap_arg_lists, list(0)),
        derefs = replace(&self.cap_derefs, list(0)),
        arg_derefs = replace(&self.cap_arg_derefs, list(0)),
        adapts = replace(&self.cap_adapts, list(0)),
    }
    return out
}

pub fn deinit(self: move InferenceResults) {
    self.node_types.deinit()
    self.resolved_ops.deinit()
    self.resolved_targets.deinit()
    self.instantiated_types.deinit()
    self.synth_strings.deinit()
    self.desugars.deinit()
    self.lambdas.deinit()
    self.default_args.deinit()
    self.arg_lists.deinit()
    self.receiver_derefs.deinit()
    self.receiver_adapts.deinit()
    self.arg_derefs.deinit()
    self.spans.deinit()
    self.cap_spans.deinit()
    self.cap_types.deinit()
    self.cap_targets.deinit()
    self.cap_ops.deinit()
    self.cap_desugars.deinit()
    self.cap_lambdas.deinit()
    self.cap_default_args.deinit()
    self.cap_arg_lists.deinit()
    self.cap_derefs.deinit()
    self.cap_arg_derefs.deinit()
    self.cap_adapts.deinit()
}

// Note the span an id was minted from. Two spans share an id only by clamping to the same bits, so
// a repeat write carries the same span.
pub fn record_span(self: &InferenceResults, id: NodeId, span: SourceSpan) {
    self.spans.set(id, span)
    if self.cap_on {
        self.cap_spans.push(id)
    }
}

pub fn get_span(self: &InferenceResults, id: NodeId) SourceSpan? {
    return self.spans.get(id)
}

// Record (or overwrite) the inferred type for a node. The "overwrite" path is the load-bearing one
// for coercion: once a coercion fires, `node_types[expr]` is rewritten to the coerced type so
// lowering sees the final shape.
pub fn record_type(self: &InferenceResults, id: NodeId, ty: Ty) {
    self.node_types.set(id, ty)
    if self.cap_on {
        self.cap_types.push(id)
    }
}

pub fn get_type(self: &InferenceResults, id: NodeId) Ty? {
    return self.node_types.get(id)
}

pub fn record_operator(self: &InferenceResults, id: NodeId, op: ResolvedOperator) {
    self.resolved_ops.set(id, op)
    if self.cap_on {
        self.cap_ops.push(id)
    }
}

pub fn record_target(self: &InferenceResults, id: NodeId, target: ResolvedTarget) {
    self.resolved_targets.set(id, target)
    if self.cap_on {
        self.cap_targets.push(id)
    }
}

pub fn record_instantiated(self: &InferenceResults, ty: Ty) {
    self.instantiated_types.push(ty)
}

// Take ownership of a synthesized string's buffer; returns the stable view the synthesized AST
// stores (an OwnedString's heap bytes do not move when the list grows).
pub fn add_synth_string(self: &InferenceResults, owned: move OwnedString) String {
    let view = owned.view
    self.synth_strings.push(owned)
    return view
}

pub fn record_desugar(self: &InferenceResults, id: NodeId, block: &BlockExpr) {
    self.desugars.set(id, block)
    if self.cap_on {
        self.cap_desugars.push(id)
    }
}

pub fn record_lambda(self: &InferenceResults, id: NodeId, info: move LambdaInfo) {
    self.lambdas.set(id, info)
    if self.cap_on {
        self.cap_lambdas.push(id)
    }
}

pub fn record_default_args(self: &InferenceResults, id: NodeId, exprs: move List(&Expr)) {
    self.default_args.set(id, exprs)
    if self.cap_on {
        self.cap_default_args.push(id)
    }
}

pub fn record_arg_list(self: &InferenceResults, id: NodeId, exprs: move List(&Expr)) {
    self.arg_lists.set(id, exprs)
    if self.cap_on {
        self.cap_arg_lists.push(id)
    }
}

pub fn record_receiver_deref(self: &InferenceResults, id: NodeId, chain: move List(ResolvedTarget)) {
    self.receiver_derefs.set(id, chain)
    if self.cap_on {
        self.cap_derefs.push(id)
    }
}

pub fn record_receiver_adapt(self: &InferenceResults, id: NodeId, adapt: ReceiverAdapt) {
    self.receiver_adapts.set(id, adapt)
    if self.cap_on {
        self.cap_adapts.push(id)
    }
}

// The argument counterpart, on the argument's own node (RFC-020).
pub fn record_arg_deref(self: &InferenceResults, id: NodeId, chain: move List(ResolvedTarget)) {
    self.arg_derefs.set(id, chain)
    if self.cap_on {
        self.cap_arg_derefs.push(id)
    }
}

// `update_receiver_deref` for an argument's chain.
pub fn update_arg_deref(self: &InferenceResults, id: NodeId, index: usize, target: ResolvedTarget) {
    let l = self.arg_derefs.get_ref(id)
    if l.is_none() {
        return
    }
    let chain = l.unwrap()
    if index >= chain.len {
        return
    }
    chain[index] = target
}

// Rewrite one hop of a recorded deref chain to its specialization - the M10 drain's counterpart of
// `record_target`'s rewrite.
pub fn update_receiver_deref(
    self: &InferenceResults,
    id: NodeId,
    index: usize,
    target: ResolvedTarget,
) {
    let l = self.receiver_derefs.get_ref(id)
    if l.is_none() {
        return
    }
    let chain = l.unwrap()
    if index >= chain.len {
        return
    }
    chain[index] = target
}

// Replace the lambda table wholesale - the zonk passes rebuild it (the field itself is
// module-private under scoped mutability).
pub fn replace_lambdas(self: &InferenceResults, ls: move Dict(NodeId, LambdaInfo)) {
    self.lambdas = move ls
}

// Replace the node-type table wholesale - the zonk passes rebuild it (scoped mutability keeps the
// field itself module-private).
pub fn replace_node_types(self: &InferenceResults, nt: move Dict(NodeId, Ty)) {
    self.node_types = move nt
}

// Append another result set's RTTI instantiations - used when a specialization overlay's entries
// surface into the program tables.
pub fn merge_instantiated(self: &InferenceResults, other: &InferenceResults) {
    self.instantiated_types.push_all(other.instantiated_types.as_slice())
}

// `op` with its specialization set - `ResolvedOperator` fields are module-private under scoped
// mutability.
pub fn with_spec(op: &ResolvedOperator, spec_id: SpecId) ResolvedOperator {
    return .{
        function_id = op.function_id,
        negate_result = op.negate_result,
        cmp_derived_op = op.cmp_derived_op,
        is_ref_form = op.is_ref_form,
        spec_id = Some(spec_id),
        lhs_hops = op.lhs_hops,
        rhs_hops = op.rhs_hops,
    }
}

// An owning copy of one lambda record - handles and views shared, lists and the symbol duplicated.
pub fn copy_lambda(info: &LambdaInfo) LambdaInfo {
    let ps: List(Ty) = list(info.params.len)
    ps.push_all(info.params.as_slice())
    let caps: List(CaptureRec) = list(info.captures.len)
    caps.push_all(info.captures.as_slice())
    return LambdaInfo {
        span = info.span,
        params = move ps,
        moves = info.moves,
        ret = info.ret,
        captures = move caps,
        closure_id = info.closure_id,
        symbol = from_view(info.symbol.view),
        conv = info.conv,
    }
}

// An owning copy of one closure dispatch record - handles shared, the params list and symbol
// duplicated.
pub fn copy_sig(sig: &ClosureSig) ClosureSig {
    let ps: List(Ty) = list(sig.params.len)
    ps.push_all(sig.params.as_slice())
    return ClosureSig {
        params = move ps,
        moves = sig.moves,
        ret = sig.ret,
        symbol = from_view(sig.symbol.view),
        lambda_node = sig.lambda_node,
    }
}

// A deep copy of a finished result set: every table an entry-by-entry copy, lambda records
// duplicated. Desugar blocks stay shared pointers (they are leaked global boxes) and the copy's
// tables keep viewing the ORIGINAL set's string buffers - `synth_strings` is left empty rather than
// copied into orphan buffers nothing views - so the copy lives only as long as its source's
// storage. Capture state starts clean.
pub fn deep_copy(self: &InferenceResults) InferenceResults {
    // Every container fills as a local and wraps at the end - growing one through a local struct's
    // field is the two-field-hop hazard.
    let node_types: Dict(NodeId, Ty) = dict(self.node_types.len())
    for e in self.node_types {
        node_types.set(e.key, e.value)
    }
    let resolved_ops: Dict(NodeId, ResolvedOperator) = dict()
    for e in self.resolved_ops {
        resolved_ops.set(e.key, e.value)
    }
    let resolved_targets: Dict(NodeId, ResolvedTarget) = dict()
    for e in self.resolved_targets {
        resolved_targets.set(e.key, e.value)
    }
    let instantiated: List(Ty) = list(self.instantiated_types.len)
    instantiated.push_all(self.instantiated_types.as_slice())
    let desugars: Dict(NodeId, &BlockExpr) = dict()
    for e in self.desugars {
        desugars.set(e.key, e.value)
    }
    let lambdas: Dict(NodeId, LambdaInfo) = dict()
    for e in self.lambdas {
        lambdas.set(e.key, copy_lambda(&e.value))
    }
    let default_args: Dict(NodeId, List(&Expr)) = dict()
    for e in self.default_args {
        let xs: List(&Expr) = list(e.value.len)
        xs.push_all(e.value.as_slice())
        default_args.set(e.key, xs)
    }
    let arg_lists: Dict(NodeId, List(&Expr)) = dict()
    for e in self.arg_lists {
        let xs: List(&Expr) = list(e.value.len)
        xs.push_all(e.value.as_slice())
        arg_lists.set(e.key, xs)
    }
    let derefs: Dict(NodeId, List(ResolvedTarget)) = dict()
    for e in self.receiver_derefs {
        let chain: List(ResolvedTarget) = list(e.value.len)
        chain.push_all(e.value.as_slice())
        derefs.set(e.key, chain)
    }
    let arg_derefs: Dict(NodeId, List(ResolvedTarget)) = dict()
    for e in self.arg_derefs {
        let chain: List(ResolvedTarget) = list(e.value.len)
        chain.push_all(e.value.as_slice())
        arg_derefs.set(e.key, chain)
    }
    let adapts: Dict(NodeId, ReceiverAdapt) = dict()
    for e in self.receiver_adapts {
        adapts.set(e.key, e.value)
    }
    let spans: Dict(NodeId, SourceSpan) = dict(self.spans.len())
    for e in self.spans {
        spans.set(e.key, e.value)
    }
    let out = inference_results()
    install(&out.node_types, node_types)
    install(&out.resolved_ops, resolved_ops)
    install(&out.resolved_targets, resolved_targets)
    install(&out.instantiated_types, instantiated)
    install(&out.desugars, desugars)
    install(&out.lambdas, lambdas)
    install(&out.default_args, default_args)
    install(&out.arg_lists, arg_lists)
    install(&out.receiver_derefs, derefs)
    install(&out.arg_derefs, arg_derefs)
    install(&out.receiver_adapts, adapts)
    install(&out.spans, spans)
    return out
}

// Each table, handed over to a snapshot: the result keeps a fresh empty one, so its own teardown
// frees nothing twice. Only this module may take its fields out (RFC-033).

pub fn take_resolved_ops(self: &InferenceResults) Dict(NodeId, ResolvedOperator) {
    const out = replace(&self.resolved_ops, dict())
    return out
}

pub fn take_resolved_targets(self: &InferenceResults) Dict(NodeId, ResolvedTarget) {
    const out = replace(&self.resolved_targets, dict())
    return out
}

pub fn take_instantiated_types(self: &InferenceResults) List(Ty) {
    const out = replace(&self.instantiated_types, list(0))
    return out
}

pub fn take_desugars(self: &InferenceResults) Dict(NodeId, &BlockExpr) {
    const out = replace(&self.desugars, dict())
    return out
}

pub fn take_synth_strings(self: &InferenceResults) List(OwnedString) {
    const out = replace(&self.synth_strings, list(0))
    return out
}

pub fn take_default_args(self: &InferenceResults) Dict(NodeId, List(&Expr)) {
    const out = replace(&self.default_args, dict())
    return out
}

pub fn take_arg_lists(self: &InferenceResults) Dict(NodeId, List(&Expr)) {
    const out = replace(&self.arg_lists, dict())
    return out
}

pub fn take_receiver_derefs(self: &InferenceResults) Dict(NodeId, List(ResolvedTarget)) {
    const out = replace(&self.receiver_derefs, dict())
    return out
}

pub fn take_receiver_adapts(self: &InferenceResults) Dict(NodeId, ReceiverAdapt) {
    const out = replace(&self.receiver_adapts, dict())
    return out
}

pub fn take_arg_derefs(self: &InferenceResults) Dict(NodeId, List(ResolvedTarget)) {
    const out = replace(&self.arg_derefs, dict())
    return out
}

pub fn take_lambdas(self: &InferenceResults) Dict(NodeId, LambdaInfo) {
    const out = replace(&self.lambdas, dict())
    return out
}

pub fn take_spans(self: &InferenceResults) Dict(NodeId, SourceSpan) {
    const out = replace(&self.spans, dict())
    return out
}
// Reset the transferred side tables to empty so a later `deinit()` can't double-free; `node_types`
// is kept.
pub fn reset_side_tables(self: &InferenceResults) {
    self.resolved_ops = dict()
    self.resolved_targets = dict()
    self.instantiated_types = list(0)
    self.synth_strings = list(0)
    self.desugars = dict()
    self.lambdas = dict()
    self.default_args = dict()
    self.arg_lists = dict()
    self.receiver_derefs = dict()
    self.receiver_adapts = dict()
    self.arg_derefs = dict()
    self.spans = dict()
}
