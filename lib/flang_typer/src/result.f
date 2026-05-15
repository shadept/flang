// TypeCheckResult — immutable snapshot consumed by lowering and the LSP.
//
// Constructed by `checker.check_all` once every phase has run and the
// final zonk pass has substituted every bound variable. The engine is
// dropped before the result is returned — there is no live
// `_resolver` for callers to fall back to. If a type isn't in
// `node_types`, the checker simply never visited that node.

import std.allocator
import std.dict
import std.list
import std.option
import flang_typer.type
import flang_typer.node_id
import flang_typer.inference_results
import flang_typer.nominal_registry
import flang_typer.function_registry

pub type TypeCheckResult = struct {
    node_types: Dict(NodeId, Ty)             // every entry zonked
    resolved_ops: Dict(NodeId, ResolvedOperator)
    resolved_targets: Dict(NodeId, ResolvedTarget)
    instantiated_types: List(Ty)
    specializations: List(NodeId)
    nominals: NominalRegistry
    functions: FunctionRegistry
}

// Look up a node's resolved type. Returns `null` for nodes the checker
// never visited (synthesised AST, unreachable arms, etc.). Callers
// that expect every node to have a type should treat `null` as a bug,
// not silently fall back to a fresh var.
pub fn get_type(self: &TypeCheckResult, id: NodeId) Ty? {
    return self.node_types.get(id)
}

pub fn get_target(self: &TypeCheckResult, id: NodeId) ResolvedTarget? {
    return self.resolved_targets.get(id)
}

pub fn get_operator(self: &TypeCheckResult, id: NodeId) ResolvedOperator? {
    return self.resolved_ops.get(id)
}
