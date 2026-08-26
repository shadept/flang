// Specialization registry - eager monomorphisation of generic functions.
//
// Each call site to a generic function whose instantiated signature
// settles to concrete types triggers one specialization. The first time
// a given `(function_id, concrete signature)` is seen, the checker
// re-checks the template's body - the ORIGINAL AST, no clone - with the
// signature's type params bound to the concrete arguments, recording
// every node type / resolved target / resolved operator into a private
// `overlay` of the result tables. Node ids are span fingerprints, so
// several instantiations of one body share ids; the overlay is what
// keeps their entries apart. Later call sites with the same signature
// reuse the existing specialization via the keyed lookup.
//
// The instantiation pass lives in the checker; this module is the dedup
// cache plus the record lowering consumes: each entry lowers the
// template's declaration once per concrete signature, reading through
// its overlay, under a symbol mangled from the concrete parameter
// types. Generic templates never reach the IR.

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.string_builder
import std.test
import flang_core.span
import flang_parser.ast
import flang_typer.type
import flang_typer.interner
import flang_typer.node_id
import flang_typer.inference_results

// One instantiated generic function. `key` is the unique signature the
// registry hashed on; `decl` is a shallow copy of the template's
// declaration (children stay in the module's arena, which outlives the
// check). `overlay` holds the instantiation's private result tables -
// empty at registration, filled in by `set_overlay` once the body
// re-check completes (registration happens first so a self-recursive
// generic finds its own key instead of recursing forever).
pub type Specialization = struct {
    id: u32
    function_id: u32              // FunctionRegistry id of the generic template
    key: OwnedString              // canonical "fn_id@arg_tys" identity
    name: String                  // template function name
    module: String                // template's defining module FQN
    decl: FunctionDecl            // template declaration (shared AST)
    concrete_params: List(Ty)
    concrete_return: Ty
    overlay: InferenceResults
}

// What one specialization owns: the key buffer, the overlay tables,
// and the concrete-params list. `decl` is a shallow copy into the
// module arena and the name/module strings are views - not ours.
pub fn deinit(self: &Specialization) {
    self.key.deinit()
    self.overlay.deinit()
    self.concrete_params.deinit()
}

pub type SpecializationRegistry = struct {
    by_key: Dict(String, u32)
    // Keyed by id, not positional - same contract as NominalRegistry:
    // ids come from `next_id`, are never reused, and an eviction leaves a
    // hole so the ids `RtSpecialized` / `ResolvedOperator.spec_id` already
    // carry keep pointing at the same entry.
    specs: Dict(u32, Specialization)
    next_id: u32
    allocator: &Allocator?
}

pub fn specialization_registry(allocator: &Allocator? = null) SpecializationRegistry {
    return .{
        by_key = dict(allocator),
        specs = dict(allocator),
        next_id = 0 as u32,
        allocator = allocator,
    }
}

pub fn deinit(self: &SpecializationRegistry) {
    self.by_key.deinit()
    self.specs.deinit()
}

// Canonical key for `(function_id, concrete_params)`. Two
// specialisations with identical signatures share an id.
pub fn key_for(it: &TypeInterner, function_id: u32, params: &List(Ty), ret: Ty, allocator: &Allocator? = null) OwnedString {
    let sb = string_builder(64, allocator)
    defer sb.deinit()
    sb.append(function_id)
    sb.append("@")
    for i in 0..params.len {
        if i > 0 { sb.append(",") }
        it.format(params[i], &sb)
    }
    sb.append("->")
    it.format(ret, &sb)
    return sb.to_string()
}

// Look up an existing specialization; `null` if none yet.
pub fn lookup(self: &SpecializationRegistry, key: String) u32? {
    return self.by_key.get(key)
}

// Register a fresh specialization. Returns the assigned id. The caller
// is expected to re-check the template body immediately after and hand
// the resulting tables back via `set_overlay` - registration comes
// first so a recursive instantiation finds its own key.
pub fn register(self: &SpecializationRegistry, spec: Specialization) u32 {
    let id: u32 = self.next_id
    self.next_id = id + 1
    let with_id = Specialization {
        id = id,
        function_id = spec.function_id,
        key = spec.key,
        name = spec.name,
        module = spec.module,
        decl = spec.decl,
        concrete_params = spec.concrete_params,
        concrete_return = spec.concrete_return,
        overlay = spec.overlay,
    }
    // `spec.key` was moved into `with_id.key` on construction; the
    // OwnedString's heap buffer is separate from the entry that holds it,
    // so a later rehash does not move it and this view remains valid for
    // the registry's life.
    let stable_view = with_id.key.as_view()
    self.by_key.set(stable_view, id)
    self.specs.set(id, with_id)
    return id
}

// Attach the completed instantiation's result tables to `id`.
pub fn set_overlay(self: &SpecializationRegistry, id: u32, overlay: InferenceResults) {
    let s = self.specs.get_ref(id).unwrap()
    s.overlay = overlay
}

// The specialization at `id`. Panics on a hole; use `find` when the id
// may be stale.
pub fn get(self: &SpecializationRegistry, id: u32) &Specialization {
    return self.specs.get_ref(id).unwrap()
}

// The specialization at `id`, or null when the id names a hole.
pub fn find(self: &SpecializationRegistry, id: u32) &Specialization? {
    return self.specs.get_ref(id)
}

// Live specializations. Not an id bound - iterate `0..next_id` and skip
// the holes for that.
pub fn len(self: &SpecializationRegistry) usize {
    return self.specs.len()
}

// Drop the specialization at `id`, its key mapping and everything it
// owns. The id is retired, not recycled.
pub fn evict(self: &SpecializationRegistry, id: u32) {
    let found = self.specs.get_ref(id)
    if found.is_none() { return }
    let live = found.unwrap()
    let _k = self.by_key.remove(live.key.as_view())
    let dropped = self.specs.remove(id)
    if dropped.is_none() { return }
    let d = dropped.unwrap()
    d.deinit()
}

test "specialization keys separate same-named types from different modules" {
    // Two modules may each declare a `Binding`; the key must tell their
    // specializations apart. Nominals are keyed by registry id, which is
    // unique per declaration - keying by a type's short name is what made
    // the reference compiler fuse two specializations into one and emit a
    // call to a symbol nothing defined (docs/known-issues.md).
    let it = type_interner()
    defer it.deinit()
    let no_args: List(Ty) = list(0)
    defer no_args.deinit()
    let a = it.nominal_of(7 as NominalId, &no_args)
    let b = it.nominal_of(9 as NominalId, &no_args)

    let pa: List(Ty) = list(1)
    pa.push(a)
    let pb: List(Ty) = list(1)
    pb.push(b)

    let ka = key_for(&it, 3 as u32, &pa, a)
    let kb = key_for(&it, 3 as u32, &pb, b)
    assert_true(ka.as_view() != kb.as_view(), "distinct nominal ids give distinct keys")

    ka.deinit()
    kb.deinit()
    pa.deinit()
    pb.deinit()
}

test "specialization keys reuse one entry for the same type" {
    let it = type_interner()
    defer it.deinit()
    let no_args: List(Ty) = list(0)
    defer no_args.deinit()
    let a = it.nominal_of(7 as NominalId, &no_args)
    let b = it.nominal_of(7 as NominalId, &no_args)
    assert_eq(a, b, "one shape, one handle")

    let pa: List(Ty) = list(1)
    pa.push(a)
    let pb: List(Ty) = list(1)
    pb.push(b)

    let ka = key_for(&it, 3 as u32, &pa, a)
    let kb = key_for(&it, 3 as u32, &pb, b)
    assert_true(ka.as_view() == kb.as_view(), "the same type keys to the same specialization")

    ka.deinit()
    kb.deinit()
    pa.deinit()
    pb.deinit()
}

test "an evicted specialization leaves a hole and never recycles its id" {
    let reg = specialization_registry()
    defer reg.deinit()
    let a = reg.register(probe_spec(1 as u32, "a"))
    let b = reg.register(probe_spec(2 as u32, "b"))
    let c = reg.register(probe_spec(3 as u32, "c"))
    assert_eq(a, 0 as u32, "ids start at zero")
    assert_eq(c, 2 as u32, "ids are handed out in registration order")

    let it = type_interner()
    defer it.deinit()
    let probe_params: List(Ty) = list(0)
    let bkey = key_for(&it, 2 as u32, &probe_params, prim_of(PrimitiveKind.I32))
    reg.evict(b)
    assert_true(reg.find(b).is_none(), "the evicted id names a hole")
    assert_true(reg.lookup(bkey.as_view()).is_none(), "the evicted key stops resolving")
    bkey.deinit()
    probe_params.deinit()
    assert_eq(reg.get(c).function_id, 3 as u32, "the id past the hole still names its own spec")
    assert_eq(reg.len(), 2 as usize, "a hole is not a live entry")

    let d = reg.register(probe_spec(4 as u32, "d"))
    assert_eq(d, 3 as u32, "a retired id is never handed out again")
}

fn probe_spec(function_id: u32, name: String) Specialization {
    let no_dirs: List(DeclAttribute) = list(0)
    let no_decl_params: List(FunctionParam) = list(0)
    let decl = FunctionDecl {
        span = none_span(), is_pub = false, directives = no_dirs,
        name = name, params = no_decl_params, return_type = null, body = null,
    }
    let it = type_interner()
    defer it.deinit()
    let no_params: List(Ty) = list(0)
    let ret = prim_of(PrimitiveKind.I32)
    return Specialization {
        id = 0 as u32,
        function_id = function_id,
        key = key_for(&it, function_id, &no_params, ret),
        name = name,
        module = "m",
        decl = decl,
        concrete_params = no_params,
        concrete_return = ret,
        overlay = inference_results(),
    }
}

// Replace a specialization's concrete signature - used when a signature
// that entered instantiation with callable-slot vars (RFC-014 lambdas
// through `$F`) settled during the body re-check.
pub fn set_signature(self: &SpecializationRegistry, id: u32, params: List(Ty), ret: Ty) {
    let s = self.specs.get_ref(id).unwrap()
    s.concrete_params.deinit()
    s.concrete_params = params
    s.concrete_return = ret
}

// Re-key a specialization under its settled signature. Returns false -
// and frees `new_key` - when a DIFFERENT spec already owns that key: the
// caller's spec stays registered under its provisional key and its
// emission dedups by symbol.
pub fn rekey(self: &SpecializationRegistry, id: u32, new_key: OwnedString) bool {
    let existing = self.by_key.get(new_key.as_view())
    if existing.is_some() {
        if existing.unwrap() != id {
            new_key.deinit()
            return false
        }
        new_key.deinit()
        return true
    }
    let s = self.specs.get_ref(id).unwrap()
    let _old = self.by_key.remove(s.key.as_view())
    s.key.deinit()
    s.key = new_key
    self.by_key.set(s.key.as_view(), id)
    return true
}
