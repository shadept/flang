// InferenceResults — mutable accumulator the checker fills in.
//
// Three primary side tables, all keyed by `NodeId`:
//
//   - `node_types`      every expression / pattern / type-expr node's
//                       final resolved type. Coerced types land here
//                       *before the engine is discarded* — lowering
//                       reads this dict and never inspects the slot.
//
//   - `resolved_ops`    resolved operator binding for each operator
//                       node (the function the `+`, `==`, `[]`, …
//                       desugared to). Null entries mean "no overload
//                       — primitive IR instruction".
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
}

pub type BinaryOpDerived = enum {
    BodEq
    BodNe
    BodLt
    BodLe
    BodGt
    BodGe
}

pub type InferenceResults = struct {
    node_types: Dict(NodeId, Ty)
    resolved_ops: Dict(NodeId, ResolvedOperator)
    resolved_targets: Dict(NodeId, ResolvedTarget)
    // Types used as `Type(T)` values (RTTI). Pre-zonked when the
    // checker finishes; consumed by codegen to emit the runtime
    // type-info table.
    instantiated_types: List(Ty)
    // Specialized generic-function bodies the checker emitted, in
    // order of first need. Indexed by `RtSpecialized.0`.
    specializations: List(NodeId)
    allocator: &Allocator
}

pub fn inference_results(allocator: &Allocator? = null) InferenceResults {
    let alloc = allocator.or_global()
    return .{
        node_types = dict(alloc),
        resolved_ops = dict(alloc),
        resolved_targets = dict(alloc),
        instantiated_types = list(0, alloc),
        specializations = list(0, alloc),
        allocator = alloc,
    }
}

pub fn deinit(self: &InferenceResults) {
    self.node_types.deinit()
    self.resolved_ops.deinit()
    self.resolved_targets.deinit()
    self.instantiated_types.deinit()
    self.specializations.deinit()
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

// Reset the transferred side tables to empty so a later `deinit()` can't
// double-free; `node_types` is kept.
pub fn reset_side_tables(self: &InferenceResults) {
    self.resolved_ops = dict(self.allocator)
    self.resolved_targets = dict(self.allocator)
    self.instantiated_types = list(0, self.allocator)
    self.specializations = list(0, self.allocator)
}
