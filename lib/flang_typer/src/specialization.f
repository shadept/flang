// Specialization registry — eager monomorphisation of generic functions.
//
// Each call site to a generic function with a concrete type-arg vector
// triggers `ensure_specialization`. The first time a given vector is
// seen, the registry clones the generic body, substitutes type-params
// for concrete args, and queues the clone for re-type-checking. Later
// call sites with the same vector reuse the existing clone via a
// `(function_id, args_hash)` lookup.
//
// The clone-and-resubstitute pass lives in the checker; this module is
// the dedup cache + the public API the checker hands back to consumers
// through `InferenceResults.specializations`. Generic templates never
// reach the IR — every monomorphisation that appears in `result.f`'s
// `specializations` list is a fully-type-checked, concrete function.

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.string_builder
import flang_typer.type
import flang_typer.node_id

// One queued (or already-checked) specialization. `key` is the unique
// signature the registry hashed on; `body_node` points at the cloned
// AST. Concrete signatures live on the registry so the checker can
// re-emit them as if they were ordinary monomorphic functions.
pub type Specialization = struct {
    id: u32
    function_id: u32              // FunctionRegistry id of the generic template
    key: OwnedString              // canonical "fn_id@arg_tys" identity
    body_node: NodeId             // the cloned AST root
    concrete_params: List(Ty)
    concrete_return: Ty
}

pub type SpecializationRegistry = struct {
    by_key: Dict(String, u32)
    specs: List(Specialization)
    allocator: &Allocator
}

pub fn specialization_registry(allocator: &Allocator? = null) SpecializationRegistry {
    let alloc = allocator.or_global()
    return .{
        by_key = dict(alloc),
        specs = list(0, alloc),
        allocator = alloc,
    }
}

pub fn deinit(self: &SpecializationRegistry) {
    for i in 0..self.specs.len {
        let s = &self.specs[i]
        let k = s.key
        k.deinit()
    }
    self.by_key.deinit()
    self.specs.deinit()
}

// Canonical key for `(function_id, concrete_params)`. Two
// specialisations with identical signatures share an id.
pub fn key_for(function_id: u32, params: &List(Ty), ret: Ty, allocator: &Allocator? = null) OwnedString {
    let alloc = allocator.or_global()
    let sb = string_builder(64, alloc)
    sb.append(function_id)
    sb.append("@")
    for i in 0..params.len {
        if i > 0 { sb.append(",") }
        let p = &params[i]
        format(p, &sb, "")
    }
    sb.append("->")
    format(&ret, &sb, "")
    return sb.to_string()
}

// Look up an existing specialization; `null` if none yet.
pub fn lookup(self: &SpecializationRegistry, key: String) u32? {
    return self.by_key.get(key)
}

// Register a freshly-cloned specialization. Returns the assigned id.
// The caller is expected to type-check the clone immediately after.
pub fn register(self: &SpecializationRegistry, spec: Specialization) u32 {
    let id: u32 = self.specs.len as u32
    let with_id = Specialization {
        id = id,
        function_id = spec.function_id,
        key = spec.key,
        body_node = spec.body_node,
        concrete_params = spec.concrete_params,
        concrete_return = spec.concrete_return,
    }
    // `spec.key` was moved into `with_id.key` on construction; the
    // OwnedString's heap buffer stays put across the later `specs.push`,
    // so this view remains valid for the registry's life.
    let stable_view = with_id.key.as_view()
    self.by_key.set(stable_view, id)
    self.specs.push(with_id)
    return id
}

pub fn get(self: &SpecializationRegistry, id: u32) &Specialization {
    return &self.specs[id as usize]
}
