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
    // Every generic instantiation the checker emitted, in first-need
    // order, each with its private overlay tables - indexed by
    // `RtSpecialized.0` / `ResolvedOperator.spec_id`. Lowering emits one
    // function per entry.
    specializations: List(Specialization)
    // Checker-synthesized replacement AST (interpolation's StringBuilder
    // desugar) keyed by the replaced node - see InferenceResults.desugars.
    desugars: Dict(NodeId, &BlockExpr)
    // Owned buffers the desugars' name/text views point into.
    synth_strings: List(OwnedString)
    // M11: per call site, the callee's default expressions for omitted
    // parameters, in parameter order - see InferenceResults.default_args.
    default_args: Dict(NodeId, List(Expr))
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
        specializations = list(0, allocator),
        desugars = dict(allocator),
        synth_strings = list(0, allocator),
        default_args = dict(allocator),
        receiver_derefs = dict(allocator),
        nominals = nominal_registry(allocator),
        functions = function_registry(allocator),
        lambdas = dict(allocator),
        closures = dict(allocator),
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
    self.receiver_derefs.deinit()
    self.nominals.deinit()
    self.functions.deinit()
    self.lambdas.deinit()
    self.closures.deinit()
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

pub fn get_receiver_deref(self: &TypeCheckResult, id: NodeId) &List(ResolvedTarget)? {
    return self.receiver_derefs.get_ref(id)
}

pub fn get_closure(self: &TypeCheckResult, id: NominalId) &ClosureSig? {
    return self.closures.get_ref(id)
}
