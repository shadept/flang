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
// Plus auxiliary state: monomorphisation outputs and unsuffixed
// literal book-keeping the checker drains in a post-inference pass.

import std.allocator
import std.dict
import std.list
import std.option
import std.set
import std.string
import flang_core.span
import flang_parser.ast
import flang_typer.type
import flang_typer.node_id

// Where a name reference points to. Distinguishing variants drives
// `goto-definition` resolution + lets the lowering pass pick the
// right code path.
pub type ResolvedTarget = enum {
    RtFunction(u32)                   // FunctionRegistry id
    RtLocal(NodeId)                   // declaration node
    RtStructField(NominalId, u32)     // nominal + field index
    RtEnumVariant(NominalId, u32)     // nominal + variant index
    RtSpecialized(u32)                // SpecializationRegistry id
    // Module-level constant, by FQN (M11 globals). The view is interned
    // into the result's `synth_strings`, so it outlives the checker.
    // Recorded on every const READ node and on the ConstDecl node itself
    // (lowering's pre-pass reads the decl's own entry to name its global).
    RtConst(String)
}

// Resolved operator dispatch. `function_id` indexes the function
// registry. `negate_result` and `cmp_derived_op` capture the derived-
// operator dispatch the C# checker uses for `!=` / `<` / `>=` (where
// you only define `==` and `<` and the others come for free).
pub type ResolvedOperator = struct {
    function_id: u32
    negate_result: bool
    // null when the operator is not derived from a comparison.
    cmp_derived_op: BinaryOpDerived?
    is_ref_form: bool
    // When the picked operator function is generic, the specialization
    // the call site instantiated (M10). Lowering calls the
    // specialization's symbol; `function_id` then names the template.
    spec_id: u32?
}

pub type BinaryOpDerived = enum {
    BodEq
    BodNe
    BodLt
    BodLe
    BodGt
    BodGe
}

// One by-value capture of a checked lambda (RFC-014): the outer local's
// name and its (eventually zonked) type.
pub type CaptureRec = struct {
    name: String
    ty: Ty
}

pub fn deinit(self: &CaptureRec) {
    // name is a source view; ty is engine-owned structure shared with the
    // type tables - neither is ours to free.
}

// One checked lambda literal, keyed by the LambdaExpr's node id in
// `InferenceResults.lambdas`. Overlay-scoped on purpose: a lambda inside
// a generic template gets one record - with its own types, captures, and
// symbol - per instantiation. Empty `captures` = bare function pointer;
// otherwise `closure_id` names the synthesized capture struct and
// `symbol` its `op_call` function.
pub type LambdaInfo = struct {
    span: SourceSpan
    params: List(Ty)
    ret: Ty
    captures: List(CaptureRec)
    closure_id: NominalId?
    symbol: OwnedString
}

pub fn deinit(self: &LambdaInfo) {
    self.params.deinit()
    self.captures.deinit()
    self.symbol.deinit()
}

// Global (not overlay-scoped) closure dispatch record: how to call a
// value whose type is the synthesized closure nominal. Keyed by
// NominalId in `Checker.closures` / `TypeCheckResult.closures` so a
// closure that traveled through a `$F` slot dispatches from any body.
// `params` excludes the `self` env pointer.
pub type ClosureSig = struct {
    params: List(Ty)
    ret: Ty
    symbol: OwnedString
    lambda_node: NodeId
}

pub fn deinit(self: &ClosureSig) {
    self.params.deinit()
    self.symbol.deinit()
}

pub type InferenceResults = struct {
    node_types: Dict(NodeId, Ty)
    resolved_ops: Dict(NodeId, ResolvedOperator)
    resolved_targets: Dict(NodeId, ResolvedTarget)
    // Types used as `Type(T)` values (RTTI). Pre-zonked when the
    // checker finishes; consumed by codegen to emit the runtime
    // type-info table.
    instantiated_types: List(Ty)
    // Owned backing buffers for checker-synthesized names and literal
    // texts (interpolation's builder locals, re-escaped segment text).
    // The synthesized AST in `desugars` references them as views, so
    // they live and die with this result set.
    synth_strings: List(OwnedString)
    // Checker-synthesized AST keyed by the node it replaces - today
    // only interpolation's StringBuilder desugar (RFC-004). Lowering
    // lowers the stored block instead of the original node. The blocks
    // are checker-allocated and share the result's lifetime.
    desugars: Dict(NodeId, &BlockExpr)
    // Checked lambda literals (RFC-014), keyed by the LambdaExpr node.
    // Lives in the result set - not a global table - so a lambda inside a
    // generic template records once per instantiation overlay.
    lambdas: Dict(NodeId, LambdaInfo)
    // M11: per call site, the callee's default expressions for the
    // parameters the call omitted, in parameter order. The exprs are
    // shallow copies of the callee declaration's AST (shared children),
    // checked at the call site so their node types land in this result
    // set. Lowering appends them after the explicit arguments. A call
    // with no entry here that is short of the callee's arity refuses.
    default_args: Dict(NodeId, List(Expr))
    // M12: per call site, the COMPLETE argument list in parameter order,
    // excluding a UFCS receiver. Recorded when the AST's own argument
    // order is not the call's argument order - a named-argument call
    // (names select their parameters) or a variadic call (the surplus
    // arguments are packed into one synthesized array literal). Lowering
    // emits this list verbatim in place of `call.args`; a call that
    // needs one and has no entry refuses.
    arg_lists: Dict(NodeId, List(Expr))
    // A UFCS call whose receiver resolved through `op_deref` hops
    // (checker's `deref_retry`), keyed by the call node: the op_deref
    // pick per hop, outermost first. Lowering calls each hop on the
    // receiver's address and passes the last hop's result as the
    // receiver argument. Generic hops are rewritten to their
    // specializations by the M10 drain, like `resolved_targets`.
    receiver_derefs: Dict(NodeId, List(ResolvedTarget))
    // Inverse of `node_id.node_id_of`: the span every id the checker
    // minted was fingerprinted from. The fingerprint clamps a span
    // longer than 64 KB or a file past 65535, so it cannot be decoded
    // back; a consumer that has a `NodeId` (`RtLocal`, a `node_types`
    // key) reads the span from here instead.
    spans: Dict(NodeId, SourceSpan)
    allocator: &Allocator?
}

pub fn inference_results(allocator: &Allocator? = null) InferenceResults {
    return .{
        node_types = dict(allocator),
        resolved_ops = dict(allocator),
        resolved_targets = dict(allocator),
        instantiated_types = list(0, allocator),
        synth_strings = list(0, allocator),
        desugars = dict(allocator),
        lambdas = dict(allocator),
        default_args = dict(allocator),
        arg_lists = dict(allocator),
        receiver_derefs = dict(allocator),
        spans = dict(allocator),
        allocator = allocator,
    }
}

pub fn deinit(self: &InferenceResults) {
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
    self.spans.deinit()
}

// Note the span an id was minted from. Two spans only ever share an id
// by clamping to the same bits, so a repeat write is the same span in
// every case a consumer can observe.
pub fn record_span(self: &InferenceResults, id: NodeId, span: SourceSpan) {
    self.spans.set(id, span)
}

pub fn get_span(self: &InferenceResults, id: NodeId) SourceSpan? {
    return self.spans.get(id)
}

// Record (or overwrite) the inferred type for a node. The "overwrite"
// path is the load-bearing one for coercion: once a coercion fires,
// `node_types[expr]` is rewritten to the coerced type so lowering
// sees the final shape.
pub fn record_type(self: &InferenceResults, id: NodeId, ty: Ty) {
    self.node_types.set(id, ty)
}

pub fn get_type(self: &InferenceResults, id: NodeId) Ty? {
    return self.node_types.get(id)
}

pub fn record_operator(self: &InferenceResults, id: NodeId, op: ResolvedOperator) {
    self.resolved_ops.set(id, op)
}

pub fn record_target(self: &InferenceResults, id: NodeId, target: ResolvedTarget) {
    self.resolved_targets.set(id, target)
}

pub fn record_instantiated(self: &InferenceResults, ty: Ty) {
    self.instantiated_types.push(ty)
}

// Take ownership of a synthesized string's buffer; returns the stable
// view the synthesized AST stores (an OwnedString's heap bytes do not
// move when the list grows).
pub fn add_synth_string(self: &InferenceResults, owned: OwnedString) String {
    let view = owned.as_view()
    self.synth_strings.push(owned)
    return view
}

pub fn record_desugar(self: &InferenceResults, id: NodeId, block: &BlockExpr) {
    self.desugars.set(id, block)
}

pub fn record_lambda(self: &InferenceResults, id: NodeId, info: LambdaInfo) {
    self.lambdas.set(id, info)
}

pub fn record_default_args(self: &InferenceResults, id: NodeId, exprs: List(Expr)) {
    self.default_args.set(id, exprs)
}

pub fn record_arg_list(self: &InferenceResults, id: NodeId, exprs: List(Expr)) {
    self.arg_lists.set(id, exprs)
}

pub fn record_receiver_deref(self: &InferenceResults, id: NodeId, chain: List(ResolvedTarget)) {
    self.receiver_derefs.set(id, chain)
}

// Rewrite one hop of a recorded deref chain to its specialization -
// the M10 drain's counterpart of `record_target`'s rewrite.
pub fn update_receiver_deref(self: &InferenceResults, id: NodeId, index: usize, target: ResolvedTarget) {
    let l = self.receiver_derefs.get(id)
    if l.is_none() { return }
    let chain = l.unwrap()
    if index >= chain.len { return }
    chain[index] = target
}

// Replace the lambda table wholesale - the zonk passes rebuild it (the
// field itself is module-private under scoped mutability).
pub fn replace_lambdas(self: &InferenceResults, ls: Dict(NodeId, LambdaInfo)) {
    self.lambdas = ls
}

// Replace the node-type table wholesale - the zonk passes rebuild it
// (scoped mutability keeps the field itself module-private).
pub fn replace_node_types(self: &InferenceResults, nt: Dict(NodeId, Ty)) {
    self.node_types = nt
}

// Append another result set's RTTI instantiations - used when a
// specialization overlay's entries surface into the program tables.
pub fn merge_instantiated(self: &InferenceResults, other: &InferenceResults) {
    let merged = self.instantiated_types
    merged.push_all(other.instantiated_types.as_slice())
    self.instantiated_types = merged
}

// `op` with its specialization set - `ResolvedOperator` fields are
// module-private under scoped mutability.
pub fn with_spec(op: &ResolvedOperator, spec_id: u32) ResolvedOperator {
    return .{
        function_id = op.function_id,
        negate_result = op.negate_result,
        cmp_derived_op = op.cmp_derived_op,
        is_ref_form = op.is_ref_form,
        spec_id = Some(spec_id),
    }
}

// Reset the transferred side tables to empty so a later `deinit()` can't
// double-free; `node_types` is kept.
pub fn reset_side_tables(self: &InferenceResults) {
    self.resolved_ops = dict(self.allocator)
    self.resolved_targets = dict(self.allocator)
    self.instantiated_types = list(0, self.allocator)
    self.synth_strings = list(0, self.allocator)
    self.desugars = dict(self.allocator)
    self.lambdas = dict(self.allocator)
    self.default_args = dict(self.allocator)
    self.arg_lists = dict(self.allocator)
    self.receiver_derefs = dict(self.allocator)
    self.spans = dict(self.allocator)
}
