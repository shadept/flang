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
import flang_parser.ast
import flang_typer.type
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
    specs: List(Specialization)
    allocator: &Allocator?
}

pub fn specialization_registry(allocator: &Allocator? = null) SpecializationRegistry {
    return .{
        by_key = dict(allocator),
        specs = list(0, allocator),
        allocator = allocator,
    }
}

pub fn deinit(self: &SpecializationRegistry) {
    self.by_key.deinit()
    self.specs.deinit()
}

// Canonical key for `(function_id, concrete_params)`. Two
// specialisations with identical signatures share an id.
pub fn key_for(function_id: u32, params: &List(Ty), ret: Ty, allocator: &Allocator? = null) OwnedString {
    let sb = string_builder(64, allocator)
    defer sb.deinit()
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

// Register a fresh specialization. Returns the assigned id. The caller
// is expected to re-check the template body immediately after and hand
// the resulting tables back via `set_overlay` - registration comes
// first so a recursive instantiation finds its own key.
pub fn register(self: &SpecializationRegistry, spec: Specialization) u32 {
    let id: u32 = self.specs.len as u32
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
    // OwnedString's heap buffer stays put across the later `specs.push`,
    // so this view remains valid for the registry's life.
    let stable_view = with_id.key.as_view()
    self.by_key.set(stable_view, id)
    self.specs.push(with_id)
    return id
}

// Attach the completed instantiation's result tables to `id`.
pub fn set_overlay(self: &SpecializationRegistry, id: u32, overlay: InferenceResults) {
    self.specs[id as usize].overlay = overlay
}

pub fn get(self: &SpecializationRegistry, id: u32) &Specialization {
    return &self.specs[id as usize]
}

test "specialization keys separate same-named types from different modules" {
    // Two modules may each declare a `Binding`; the key must tell their
    // specializations apart. Nominals are keyed by registry id, which is
    // unique per declaration - keying by a type's short name is what made
    // the reference compiler fuse two specializations into one and emit a
    // call to a symbol nothing defined (docs/known-issues.md).
    let a_args: List(Ty) = list(0)
    let b_args: List(Ty) = list(0)
    let a = Ty.Nominal(NominalRef { id = 7 as NominalId, args = a_args })
    let b = Ty.Nominal(NominalRef { id = 9 as NominalId, args = b_args })

    let pa: List(Ty) = list(1)
    pa.push(a)
    let pb: List(Ty) = list(1)
    pb.push(b)

    let ka = key_for(3 as u32, &pa, a)
    let kb = key_for(3 as u32, &pb, b)
    assert_true(ka.as_view() != kb.as_view(), "distinct nominal ids give distinct keys")

    ka.deinit()
    kb.deinit()
    pa.deinit()
    pb.deinit()
}

test "specialization keys reuse one entry for the same type" {
    let a_args: List(Ty) = list(0)
    let b_args: List(Ty) = list(0)
    let a = Ty.Nominal(NominalRef { id = 7 as NominalId, args = a_args })
    let b = Ty.Nominal(NominalRef { id = 7 as NominalId, args = b_args })

    let pa: List(Ty) = list(1)
    pa.push(a)
    let pb: List(Ty) = list(1)
    pb.push(b)

    let ka = key_for(3 as u32, &pa, a)
    let kb = key_for(3 as u32, &pb, b)
    assert_true(ka.as_view() == kb.as_view(), "the same type keys to the same specialization")

    ka.deinit()
    kb.deinit()
    pa.deinit()
    pb.deinit()
}

// Replace a specialization's concrete signature - used when a signature
// that entered instantiation with callable-slot vars (RFC-014 lambdas
// through `$F`) settled during the body re-check.
pub fn set_signature(self: &SpecializationRegistry, id: u32, params: List(Ty), ret: Ty) {
    let s = &self.specs[id as usize]
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
    let s = &self.specs[id as usize]
    let _old = self.by_key.remove(s.key.as_view())
    s.key.deinit()
    s.key = new_key
    self.by_key.set(s.key.as_view(), id)
    return true
}
