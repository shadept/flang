// TypeCheckResult - immutable snapshot consumed by lowering and the LSP.
//
// Constructed by `checker.check_all` once every phase has run and the
// final zonk pass has substituted every bound variable. The engine is
// dropped before the result is returned - there is no live
// `_resolver` for callers to fall back to. If a type isn't in
// `node_types`, the checker simply never visited that node.

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import flang_core.span
import flang_parser.ast
import flang_typer.type
import flang_typer.node_id
import flang_typer.inference_results
import flang_typer.nominal_registry
import flang_typer.function_registry
import flang_typer.specialization

pub type TypeCheckResult = struct {
    node_types: Dict(NodeId, Ty)             // every entry zonked
    resolved_ops: Dict(NodeId, ResolvedOperator)
    resolved_targets: Dict(NodeId, ResolvedTarget)
    instantiated_types: List(Ty)
    // Every generic instantiation the checker emitted, keyed by the id
    // `RtSpecialized.0` / `ResolvedOperator.spec_id` carry, each with its
    // private overlay tables. Lowering emits one function per entry and
    // walks `0..next_id` so emission order is first-need order.
    specializations: SpecializationRegistry
    // Checker-synthesized replacement AST (interpolation's StringBuilder
    // desugar) keyed by the replaced node - see InferenceResults.desugars.
    desugars: Dict(NodeId, &BlockExpr)
    // Owned buffers the desugars' name/text views point into.
    synth_strings: List(OwnedString)
    // M11: per call site, the callee's default expressions for omitted
    // parameters, in parameter order - see InferenceResults.default_args.
    default_args: Dict(NodeId, List(Expr))
    // M12: per call site, the complete parameter-ordered argument list
    // for calls whose AST order is not their argument order (named
    // arguments, variadic packing) - see InferenceResults.arg_lists.
    arg_lists: Dict(NodeId, List(Expr))
    // Per UFCS call site, the op_deref hops the receiver resolved
    // through - see InferenceResults.receiver_derefs.
    receiver_derefs: Dict(NodeId, List(ResolvedTarget))
    nominals: NominalRegistry
    functions: FunctionRegistry
    // RFC-014: checked lambda literals of the PROGRAM tables (a lambda in
    // a generic template records per-instantiation, in that
    // specialization's overlay instead), and the global closure dispatch
    // table keyed by synthesized-nominal id.
    lambdas: Dict(NodeId, LambdaInfo)
    closures: Dict(NominalId, ClosureSig)
    // The span every recorded `NodeId` was minted from. A node id is a
    // lossy fingerprint of `(file_id, start, length)`; this table is what
    // maps one back, for `RtLocal` and for walking `node_types`.
    spans: Dict(NodeId, SourceSpan)
    // Source path per file id: `file_paths[span.file_id]`. Owned copies, so
    // the snapshot describes its own spans on its own. Empty when the
    // checker ran without paths.
    file_paths: List(OwnedString)
    // Wall time of each `check_all` phase, for `--timings`.
    phases: CheckPhases
}

// Per-phase wall time of one `check_all` run, in nanoseconds. Zero on an
// empty result. Ordered as the phases run.
pub type CheckPhases = struct {
    collect_ns: u64      // visibility graph + nominal names
    templates_ns: u64    // source-generator expansion
    nominals_ns: u64     // nominal bodies + signatures
    constants_ns: u64    // constant initializers
    bodies_ns: u64       // function bodies
    specialize_ns: u64   // generic instantiation drain + pending calls
    zonk_ns: u64         // final substitution of every recorded type
}

pub fn no_phases() CheckPhases {
    return .{
        collect_ns = 0,
        templates_ns = 0,
        nominals_ns = 0,
        constants_ns = 0,
        bodies_ns = 0,
        specialize_ns = 0,
        zonk_ns = 0,
    }
}

// Look up a node's resolved type. Returns `null` for nodes the checker
// never visited (synthesised AST, unreachable arms, etc.). Callers
// that expect every node to have a type should treat `null` as a bug,
// not silently fall back to a fresh var.
// An empty result - every table empty, registries fresh. Handed back when
// a source failed to parse and was never type-checked.
pub fn empty_result(allocator: &Allocator? = null) TypeCheckResult {
    return .{
        node_types = dict(allocator),
        resolved_ops = dict(allocator),
        resolved_targets = dict(allocator),
        instantiated_types = list(0, allocator),
        specializations = specialization_registry(allocator),
        desugars = dict(allocator),
        synth_strings = list(0, allocator),
        default_args = dict(allocator),
        arg_lists = dict(allocator),
        receiver_derefs = dict(allocator),
        nominals = nominal_registry(allocator),
        functions = function_registry(allocator),
        lambdas = dict(allocator),
        closures = dict(allocator),
        spans = dict(allocator),
        file_paths = list(0, allocator),
        phases = no_phases(),
    }
}

// Free everything the snapshot owns. The desugars' AST blocks are
// global-allocator boxes deliberately leaked (see checker.f synth
// helpers).
pub fn deinit(self: &TypeCheckResult) {
    self.node_types.deinit()
    self.resolved_ops.deinit()
    self.resolved_targets.deinit()
    self.instantiated_types.deinit()
    self.specializations.deinit()
    self.desugars.deinit()
    self.synth_strings.deinit()
    self.default_args.deinit()
    self.arg_lists.deinit()
    self.receiver_derefs.deinit()
    self.nominals.deinit()
    self.functions.deinit()
    self.lambdas.deinit()
    self.closures.deinit()
    self.spans.deinit()
    self.file_paths.deinit()
}

pub fn get_type(self: &TypeCheckResult, id: NodeId) Ty? {
    return self.node_types.get(id)
}

pub fn get_target(self: &TypeCheckResult, id: NodeId) ResolvedTarget? {
    return self.resolved_targets.get(id)
}

pub fn get_operator(self: &TypeCheckResult, id: NodeId) ResolvedOperator? {
    return self.resolved_ops.get(id)
}

pub fn get_desugar(self: &TypeCheckResult, id: NodeId) &BlockExpr? {
    return self.desugars.get(id)
}

pub fn get_lambda(self: &TypeCheckResult, id: NodeId) &LambdaInfo? {
    return self.lambdas.get_ref(id)
}

pub fn get_default_args(self: &TypeCheckResult, id: NodeId) &List(Expr)? {
    return self.default_args.get_ref(id)
}

pub fn get_arg_list(self: &TypeCheckResult, id: NodeId) &List(Expr)? {
    return self.arg_lists.get_ref(id)
}

pub fn get_receiver_deref(self: &TypeCheckResult, id: NodeId) &List(ResolvedTarget)? {
    return self.receiver_derefs.get_ref(id)
}

pub fn get_closure(self: &TypeCheckResult, id: NominalId) &ClosureSig? {
    return self.closures.get_ref(id)
}

// The source span a node id was minted from. `null` for an id the
// checker never recorded - a hand-built id, or one from a different
// compilation.
pub fn get_span(self: &TypeCheckResult, id: NodeId) SourceSpan? {
    return self.spans.get(id)
}

// The source path a span's `file_id` names. `null` for the synthetic
// file ids (`none_span`'s -1, the checker's -2) and for a result checked
// without paths.
pub fn path_of(self: &TypeCheckResult, file_id: i32) String? {
    if file_id < 0 { return null }
    const i = file_id as usize
    if i >= self.file_paths.len { return null }
    return Some(self.file_paths[i].as_view())
}
