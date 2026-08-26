// TypeCheckResult - immutable snapshot consumed by lowering and the LSP.
//
// Constructed by `checker.check_all` once every phase has run and the final zonk pass has
// substituted every bound variable. The engine is dropped before the result is returned - there is
// no live `_resolver` for callers to fall back to. If a type isn't in `node_types`, the checker
// simply never visited that node.

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
import flang_typer.interner
import flang_typer.nominal_registry
import flang_typer.function_registry
import flang_typer.specialization

pub type TypeCheckResult = struct {
    node_types: Dict(NodeId, Ty) // every entry zonked
    // The type table (RFC-024): one node per distinct type. Every `Ty` this snapshot's tables hold
    // is a canonical copy sharing its heap, so the interner owns the type storage and travels with
    // the result. It is one table per PROJECT, not per check: the next demand adopts it back
    // (`take_interner`), appends, and ships it with its own result. The table only grows, so an
    // earlier snapshot's handles stay valid in whichever result holds it now.
    interner: TypeInterner
    resolved_ops: Dict(NodeId, ResolvedOperator)
    resolved_targets: Dict(NodeId, ResolvedTarget)
    instantiated_types: List(Ty)
    // Every generic instantiation the checker emitted, keyed by the id `RtSpecialized.0` /
    // `ResolvedOperator.spec_id` carry, each with its private overlay tables. Lowering emits one
    // function per entry and walks `0..next_id` so emission order is first-need order.
    specializations: SpecializationRegistry
    // Checker-synthesized replacement AST (interpolation's StringBuilder desugar) keyed by the
    // replaced node - see InferenceResults.desugars.
    desugars: Dict(NodeId, &BlockExpr)
    // Owned buffers the desugars' name/text views point into.
    synth_strings: List(OwnedString)
    // M11: per call site, the callee's default expressions for omitted parameters, in parameter
    // order - see InferenceResults.default_args.
    default_args: Dict(NodeId, List(Expr))
    // M12: per call site, the complete parameter-ordered argument list for calls whose AST order is
    // not their argument order (named arguments, variadic packing) - see
    // InferenceResults.arg_lists.
    arg_lists: Dict(NodeId, List(Expr))
    // Per UFCS call site, the op_deref hops the receiver resolved through - see
    // InferenceResults.receiver_derefs.
    receiver_derefs: Dict(NodeId, List(ResolvedTarget))
    nominals: NominalRegistry
    functions: FunctionRegistry
    // RFC-014: checked lambda literals of the PROGRAM tables (a lambda in a generic template
    // records per-instantiation, in that specialization's overlay instead), and the global closure
    // dispatch table keyed by synthesized-nominal id.
    lambdas: Dict(NodeId, LambdaInfo)
    closures: Dict(NominalId, ClosureSig)
    // The span every recorded `NodeId` was minted from. A node id is a lossy fingerprint of
    // `(file_id, start, length)`; this table is what maps one back, for `RtLocal` and for walking
    // `node_types`.
    spans: Dict(NodeId, SourceSpan)
    // Source path per file id: `file_paths[span.file_id]`. Owned copies, so the snapshot describes
    // its own spans on its own. Empty when the checker ran without paths.
    file_paths: List(OwnedString)
    // Wall time of each `check_all` phase, for `--timings`.
    phases: CheckPhases
}

// Per-phase wall time of one `check_all` run, in nanoseconds. Zero on an empty result. Ordered as
// the phases run.
pub type CheckPhases = struct {
    visibility_ns: u64 // import graph -> per-module visible set
    collect_ns: u64 // nominal names
    templates_ns: u64 // source-generator expansion
    nominals_ns: u64 // nominal bodies
    signatures_ns: u64 // function signatures + constant types
    constants_ns: u64 // constant initializers
    bodies_ns: u64 // function bodies
    specialize_ns: u64 // generic instantiation drain + pending calls
    zonk_ns: u64 // final substitution of every recorded type
}

pub fn no_phases() CheckPhases {
    return .{
        visibility_ns = 0,
        collect_ns = 0,
        templates_ns = 0,
        nominals_ns = 0,
        signatures_ns = 0,
        constants_ns = 0,
        bodies_ns = 0,
        specialize_ns = 0,
        zonk_ns = 0,
    }
}

// Look up a node's resolved type. Returns `null` for nodes the checker never visited (synthesised
// AST, unreachable arms, etc.). Callers that expect every node to have a type should treat `null`
// as a bug, not silently fall back to a fresh var. An empty result - every table empty, registries
// fresh. Handed back when a source failed to parse and was never type-checked. The interner is a
// zero-capacity stand-in: nothing resolves through an empty result.
pub fn empty_result(allocator: &Allocator? = null) TypeCheckResult {
    return .{
        node_types = dict(allocator),
        interner = type_interner(allocator, 0),
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

// Free everything the snapshot owns. The desugars' AST blocks are global-allocator boxes
// deliberately leaked (see checker.f synth helpers).
pub fn deinit(self: &TypeCheckResult) {
    self.node_types.deinit()
    self.interner.deinit()
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

// One table's footprint. `bytes` is the backing array only: what an entry's value owns on the heap
// of its own (a `Ty`'s argument list, an `OwnedString`'s buffer) belongs to whatever measures that
// heap.
pub type TableSize = struct {
    name: String
    entries: usize
    bytes: usize
}

fn dict_size(name: String, d: &Dict($K, $V)) TableSize {
    return .{ name = name, entries = d.length, bytes = d.capacity_bytes() }
}

fn list_size(name: String, l: &List($T)) TableSize {
    return .{ name = name, entries = l.len, bytes = l.capacity_bytes() }
}

// Every table the snapshot holds, largest first. The specialization row folds in the
// per-instantiation overlay tables, which are `specializations.len()` separate `InferenceResults`
// and are counted nowhere else.
pub fn table_sizes(self: &TypeCheckResult, allocator: &Allocator? = null) List(TableSize) {
    let out: List(TableSize) = list(16, allocator)
    out.push(dict_size("node_types", &self.node_types))
    out.push(dict_size("spans", &self.spans))
    out.push(dict_size("resolved_targets", &self.resolved_targets))
    out.push(dict_size("resolved_ops", &self.resolved_ops))
    out.push(dict_size("desugars", &self.desugars))
    out.push(dict_size("default_args", &self.default_args))
    out.push(dict_size("arg_lists", &self.arg_lists))
    out.push(dict_size("receiver_derefs", &self.receiver_derefs))
    out.push(dict_size("lambdas", &self.lambdas))
    out.push(dict_size("closures", &self.closures))
    out.push(list_size("instantiated_types", &self.instantiated_types))
    out.push(list_size("synth_strings", &self.synth_strings))
    out.push(list_size("file_paths", &self.file_paths))
    out.push(.{
        name = "type interner",
        entries = self.interner.len(),
        bytes = self.interner.capacity_bytes(),
    })
    out.push(overlay_size(&self.specializations))
    sort_by_bytes(&out)
    return out
}

// The specialization registry plus every overlay hanging off it.
fn overlay_size(specs: &SpecializationRegistry) TableSize {
    let bytes = specs.specs.capacity_bytes() + specs.by_key.capacity_bytes()
    let entries: usize = 0
    for i in 0..(specs.next_id as usize) {
        const found = specs.specs.get_ref(i as u32)
        if found.is_none() {
            continue
        }
        const o = &found.unwrap().overlay
        bytes = bytes + o.node_types.capacity_bytes()
        bytes = bytes + o.resolved_ops.capacity_bytes()
        bytes = bytes + o.resolved_targets.capacity_bytes()
        bytes = bytes + o.desugars.capacity_bytes()
        bytes = bytes + o.lambdas.capacity_bytes()
        bytes = bytes + o.default_args.capacity_bytes()
        bytes = bytes + o.arg_lists.capacity_bytes()
        bytes = bytes + o.receiver_derefs.capacity_bytes()
        bytes = bytes + o.spans.capacity_bytes()
        bytes = bytes + o.instantiated_types.capacity_bytes()
        bytes = bytes + o.synth_strings.capacity_bytes()
        entries = entries + o.node_types.length
    }
    return .{ name = "specializations + overlays", entries = entries, bytes = bytes }
}

fn sort_by_bytes(xs: &List(TableSize)) {
    for i in 1..xs.len {
        const v = xs[i]
        let j = i
        while j > 0 and xs[j - 1].bytes < v.bytes {
            xs[j] = xs[j - 1]
            j = j - 1
        }
        xs[j] = v
    }
}

// Move the type table out of the snapshot, leaving a zero-capacity stand-in. The next demand adopts
// the table so the handles its carried registry holds stay resolvable; this snapshot's own handles
// remain valid in the table wherever it now lives, but no longer resolve through this struct.
pub fn take_interner(self: &TypeCheckResult) TypeInterner {
    let out = self.interner
    self.interner = type_interner(out.allocator, 0)
    return out
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

// The source span a node id was minted from. `null` for an id the checker never recorded - a
// hand-built id, or one from a different compilation.
pub fn get_span(self: &TypeCheckResult, id: NodeId) SourceSpan? {
    return self.spans.get(id)
}

// The source path a span's `file_id` names. `null` for the synthetic file ids (`none_span`'s -1,
// the checker's -2) and for a result checked without paths.
pub fn path_of(self: &TypeCheckResult, file_id: i32) String? {
    if file_id < 0 {
        return null
    }
    const i = file_id as usize
    if i >= self.file_paths.len {
        return null
    }
    return Some(self.file_paths[i].as_view())
}
