// Specialization registry - eager monomorphisation of generic functions.
//
// Each call site to a generic function whose instantiated signature settles to concrete types
// triggers one specialization. The first time a given `(function_id, concrete signature)` is seen,
// the checker re-checks the template's body - the ORIGINAL AST, no clone - with the signature's
// type params bound to the concrete arguments, recording every node type / resolved target /
// resolved operator into a private `overlay` of the result tables. Node ids are span fingerprints,
// so several instantiations of one body share ids; the overlay is what keeps their entries apart.
// Later call sites with the same signature reuse the existing specialization via the keyed lookup.
//
// The instantiation pass lives in the checker; this module is the dedup cache plus the record
// lowering consumes: each entry lowers the template's declaration once per concrete signature,
// reading through its overlay, under a symbol mangled from the concrete parameter types. Generic
// templates never reach the IR.

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

// A closure environment a body pass registered: enough to register it again at the id it held.
// Cached per module slot (checker's body cache) and per specialization (a reused specialization
// replays its frame's registrations). Field name views point into kept sources; the fqn is a
// cache-owned copy of the synthesized name whose retirement `recycled` remembers.
pub type ClosureFact = struct {
    id: NominalId
    fqn: OwnedString
    module: String
    fields: List(Field)
    decl_span: SourceSpan
    sig: ClosureSig
}

pub fn deinit(self: &ClosureFact) {
    self.fqn.deinit()
    self.fields.deinit()
    self.sig.deinit()
}

pub fn clone_fact(f: &ClosureFact, allocator: &Allocator? = null) ClosureFact {
    let fields: List(Field) = list(f.fields.len, allocator)
    fields.push_all(f.fields.as_slice())
    return ClosureFact {
        id = f.id,
        fqn = from_view(f.fqn.as_view(), allocator),
        module = f.module,
        fields = fields,
        decl_span = f.decl_span,
        sig = copy_sig(&f.sig, allocator),
    }
}

// One specialization an instantiation frame's drain resolved, in process order: the call site, the
// template, and the entry it landed on. Doubles as a reuse hint - a later demand's pick at the same
// site lands on the same id even when its provisional key cannot match the stored final key.
pub type SpecDep = struct {
    span: SourceSpan
    function_id: u32
    id: SpecId
}

pub fn deinit(self: &SpecDep) {}

// One instantiated generic function. `key` is the unique signature the registry hashed on; `decl`
// is a shallow copy of the template's declaration (children stay in the module's arena, which
// outlives the check). `overlay` holds the instantiation's private result tables - empty at
// registration, filled in by `set_overlay` once the body re-check completes (registration happens
// first so a self-recursive generic finds its own key instead of recursing forever).
pub type Specialization = struct {
    id: SpecId
    function_id: u32 // FunctionRegistry id of the generic template
    key: OwnedString // canonical "fn_id@arg_tys" identity
    name: String // template function name
    module: String // template's defining module FQN
    decl: FunctionDecl // template declaration (shared AST)
    concrete_params: List(Ty)
    concrete_return: Ty
    overlay: InferenceResults

    // Reuse bookkeeping. An entry carried from an earlier demand can be REUSED - its counter burns
    // replayed, its closures re-registered, the body re-check skipped - while everything its body
    // resolved against holds still. `touched_gen` is the demand generation that last demanded it;
    // `sweep` evicts entries left untouched. `stale` marks an entry whose template module was
    // re-parsed this demand. `reusable` is false when the frame did anything a reuse cannot replay:
    // a diagnostic, a parked call, a literal the sweep flagged, a signature that never settled
    // concrete. `harvested` is false between registration and the demand-end harvest that fills
    // `closures` and finalizes `reusable`.
    touched_gen: u64
    stale: bool
    reusable: bool
    harvested: bool
    // Stream anchors: the variable / synthetic-node / lambda counters when the body re-check began,
    // and how many of each the frame minted ITSELF - nested instantiations subtract out, since they
    // burn their own on reuse. The cached closure symbols bake counter values, so a reuse is valid
    // only from the exact positions the frame once ran at.
    vars_at: u32
    synth_at: u32
    lambda_at: u32
    own_var_burn: u32
    own_synth_burn: u32
    own_lambda_burn: u32
    // The specializations this frame's drain resolved, in process order.
    deps: List(SpecDep)
    // Closure environments the frame registered, replayed on reuse.
    closures: List(ClosureFact)
}

// A fresh record with its reuse bookkeeping zeroed; `register` / `replace_at` stamp the demand
// generation and assign the id.
pub fn new_specialization(function_id: u32, key: OwnedString, name: String, module: String,
    decl: FunctionDecl, concrete_params: List(Ty), concrete_return: Ty, overlay: InferenceResults,
    allocator: &Allocator? = null) Specialization {
    return Specialization {
        id = 0 as SpecId,
        function_id = function_id,
        key = key,
        name = name,
        module = module,
        decl = decl,
        concrete_params = concrete_params,
        concrete_return = concrete_return,
        overlay = overlay,
        touched_gen = 0 as u64,
        stale = false,
        reusable = true,
        harvested = false,
        vars_at = 0 as u32,
        synth_at = 0 as u32,
        lambda_at = 0 as u32,
        own_var_burn = 0 as u32,
        own_synth_burn = 0 as u32,
        own_lambda_burn = 0 as u32,
        deps = list(0, allocator),
        closures = list(0, allocator),
    }
}

// What one specialization owns: the key buffer, the overlay tables, the concrete-params list, and
// the reuse bookkeeping. `decl` is a shallow copy into the module arena and the name/module strings
// are views - not ours.
pub fn deinit(self: &Specialization) {
    self.key.deinit()
    self.overlay.deinit()
    self.concrete_params.deinit()
    self.deps.deinit()
    self.closures.deinit()
}

pub type SpecializationRegistry = struct {
    by_key: Dict(String, SpecId)
    // Keyed by id, not positional - same contract as NominalRegistry: ids come from `next_id`, are
    // never reused, and an eviction leaves a hole so the ids `RtSpecialized` /
    // `ResolvedOperator.spec_id` already carry keep pointing at the same entry.
    specs: Dict(SpecId, Specialization)
    next_id: SpecId
    // Demand generation: bumped once per `check_all`, stamped onto every entry that demand
    // registers, replaces or reuses. The registry travels with the result and is adopted back by
    // the next demand, so the counter is monotone across a project's life.
    gen: u64
    allocator: &Allocator?
}

pub fn specialization_registry(allocator: &Allocator? = null) SpecializationRegistry {
    return .{
        by_key = dict(allocator),
        specs = dict(allocator),
        next_id = 0 as SpecId,
        gen = 0 as u64,
        allocator = allocator,
    }
}

pub fn deinit(self: &SpecializationRegistry) {
    self.by_key.deinit()
    self.specs.deinit()
}

// Canonical key for `(function_id, concrete_params)`. Two specialisations with identical signatures
// share an id.
pub fn key_for(it: &TypeInterner, function_id: u32, params: &List(Ty), ret: Ty,
    allocator: &Allocator? = null) OwnedString {
    let sb = string_builder(64, allocator)
    defer sb.deinit()
    sb.append(function_id)
    sb.append("@")
    for i in 0..params.len {
        if i > 0 {
            sb.append(",")
        }
        it.format(params[i], &sb)
    }
    sb.append("->")
    it.format(ret, &sb)
    return sb.to_string()
}

// Look up an existing specialization; `null` if none yet.
pub fn lookup(self: &SpecializationRegistry, key: String) SpecId? {
    return self.by_key.get(key)
}

// Register a fresh specialization. Returns the assigned id. The caller is expected to re-check the
// template body immediately after and hand the resulting tables back via `set_overlay` -
// registration comes first so a recursive instantiation finds its own key.
pub fn register(self: &SpecializationRegistry, spec: Specialization) SpecId {
    let id: SpecId = self.next_id
    self.next_id = id + 1
    let with_id = spec
    with_id.id = id
    with_id.touched_gen = self.gen
    // The OwnedString's heap buffer is separate from the entry that holds it, so a later rehash
    // does not move it and this view remains valid for the registry's life.
    let stable_view = with_id.key.as_view()
    self.by_key.set(stable_view, id)
    self.specs.set(id, with_id)
    return id
}

// Re-register `id` in place with a fresh record - same id, new key, new overlay. The old entry's
// contents are freed; the ids other caches carry keep pointing at the same entry.
pub fn replace_at(self: &SpecializationRegistry, id: SpecId, spec: Specialization) {
    let old = self.specs.remove(id)
    if old.is_some() {
        let d = old.unwrap()
        let _k = self.by_key.remove(d.key.as_view())
        d.deinit()
    }
    let with_id = spec
    with_id.id = id
    with_id.touched_gen = self.gen
    let stable_view = with_id.key.as_view()
    self.by_key.set(stable_view, id)
    self.specs.set(id, with_id)
}

// Attach the completed instantiation's result tables to `id`.
pub fn set_overlay(self: &SpecializationRegistry, id: SpecId, overlay: InferenceResults) {
    let s = self.specs.get_ref(id).unwrap()
    s.overlay = overlay
}

// The specialization at `id`. Panics on a hole; use `find` when the id may be stale.
pub fn get(self: &SpecializationRegistry, id: SpecId) &Specialization {
    return self.specs.get_ref(id).unwrap()
}

// The specialization at `id`, or null when the id names a hole.
pub fn find(self: &SpecializationRegistry, id: SpecId) &Specialization? {
    return self.specs.get_ref(id)
}

// Live specializations. Not an id bound - iterate `0..next_id` and skip the holes for that.
pub fn len(self: &SpecializationRegistry) usize {
    return self.specs.len()
}

// Drop the specialization at `id`, its key mapping and everything it owns. The id is retired, not
// recycled.
pub fn evict(self: &SpecializationRegistry, id: SpecId) {
    let found = self.specs.get_ref(id)
    if found.is_none() {
        return
    }
    let live = found.unwrap()
    let _k = self.by_key.remove(live.key.as_view())
    let dropped = self.specs.remove(id)
    if dropped.is_none() {
        return
    }
    let d = dropped.unwrap()
    d.deinit()
}

// Start a new demand generation: entries the demand never touches are `sweep`'s victims.
pub fn begin_gen(self: &SpecializationRegistry) {
    self.gen = self.gen + 1
}

// Stamp `id` as demanded by the current generation.
pub fn stamp_touched(self: &SpecializationRegistry, id: SpecId) {
    let s = self.specs.get_ref(id).unwrap()
    s.touched_gen = self.gen
}

pub fn mark_stale(self: &SpecializationRegistry, id: SpecId) {
    let found = self.specs.get_ref(id)
    if found.is_none() {
        return
    }
    let s = found.unwrap()
    s.stale = true
}

pub fn mark_unreusable(self: &SpecializationRegistry, id: SpecId) {
    let found = self.specs.get_ref(id)
    if found.is_none() {
        return
    }
    let s = found.unwrap()
    s.reusable = false
}

// Move a spec's dep list out - the reuse hints its in-place re-instantiation matches nested picks
// against.
pub fn take_deps(self: &SpecializationRegistry, id: SpecId) List(SpecDep) {
    let s = self.specs.get_ref(id).unwrap()
    let out = s.deps
    s.deps = list(0, self.allocator)
    return out
}

// Frame bookkeeping, recorded when an instantiation's body re-check finishes: the stream anchors,
// the frame's own counter burns, the deps its drain resolved, and whether the frame stayed
// replayable (`reusable` is finalized at harvest).
pub fn set_cache_info(self: &SpecializationRegistry, id: SpecId, vars_at: u32, synth_at: u32,
    lambda_at: u32, own_vars: u32, own_synth: u32, own_lambda: u32, deps: List(SpecDep),
    reusable: bool) {
    let s = self.specs.get_ref(id).unwrap()
    s.vars_at = vars_at
    s.synth_at = synth_at
    s.lambda_at = lambda_at
    s.own_var_burn = own_vars
    s.own_synth_burn = own_synth
    s.own_lambda_burn = own_lambda
    s.deps.deinit()
    s.deps = deps
    s.reusable = reusable
    s.stale = false
    s.harvested = false
}

// Demand-end harvest: the closure facts a reuse replays, and the signature-concreteness half of
// `reusable` - a signature that never settled cannot be told from one a later demand's pick would
// pin differently.
pub fn finish_harvest(self: &SpecializationRegistry, id: SpecId, closures: List(ClosureFact),
    sig_is_concrete: bool) {
    let s = self.specs.get_ref(id).unwrap()
    s.closures.deinit()
    s.closures = closures
    if !sig_is_concrete {
        s.reusable = false
    }
    s.harvested = true
}

// Evict every entry the current generation never touched - a call site an edit removed keeps no
// specialization alive. A touched entry's deps are always touched with it, so eviction only ever
// removes whole undemanded subgraphs and no live dep list is left citing a hole.
pub fn sweep(self: &SpecializationRegistry) {
    let doomed: List(SpecId) = list(0, self.allocator)
    for i in 0..(self.next_id as usize) {
        const found = self.specs.get_ref(i as SpecId)
        if found.is_none() {
            continue
        }
        if found.unwrap().touched_gen != self.gen {
            doomed.push(i as SpecId)
        }
    }
    for id in doomed {
        self.evict(id)
    }
    doomed.deinit()
}

// Drop every entry and start numbering from zero, keeping the demand generation - the fallback when
// a global invalidation makes every carried entry unusable, exactly a cold check.
pub fn reset(self: &SpecializationRegistry) {
    const g = self.gen
    const a = self.allocator
    self.deinit()
    self.* = specialization_registry(a)
    self.gen = g
}

// A deep copy, for a caller that must keep the original readable after the registry moves on (gate
// A keeps retired results whole). `decl` stays a shallow AST copy and name/module stay views -
// their storage is retired, not freed. The overlay copies share desugar blocks and view the
// original result's string buffers, so the copy lives only as long as its source's retirement.
pub fn carried_copy(self: &SpecializationRegistry,
    allocator: &Allocator? = null) SpecializationRegistry {
    // The dicts fill as locals and wrap at the end - growing a container through a local struct's
    // field is the two-field-hop hazard.
    let by_key: Dict(String, SpecId) = dict(allocator)
    let specs: Dict(SpecId, Specialization) = dict(allocator)
    for i in 0..(self.next_id as usize) {
        const found = self.specs.get_ref(i as SpecId)
        if found.is_none() {
            continue
        }
        const s = found.unwrap()
        let params: List(Ty) = list(s.concrete_params.len, allocator)
        params.push_all(s.concrete_params.as_slice())
        let deps: List(SpecDep) = list(s.deps.len, allocator)
        deps.push_all(s.deps.as_slice())
        let facts: List(ClosureFact) = list(s.closures.len, allocator)
        for &f in s.closures {
            facts.push(clone_fact(f, allocator))
        }
        let copy = Specialization {
            id = s.id,
            function_id = s.function_id,
            key = from_view(s.key.as_view(), allocator),
            name = s.name,
            module = s.module,
            decl = s.decl,
            concrete_params = params,
            concrete_return = s.concrete_return,
            overlay = deep_copy(&s.overlay, allocator),
            touched_gen = s.touched_gen,
            stale = s.stale,
            reusable = s.reusable,
            harvested = s.harvested,
            vars_at = s.vars_at,
            synth_at = s.synth_at,
            lambda_at = s.lambda_at,
            own_var_burn = s.own_var_burn,
            own_synth_burn = s.own_synth_burn,
            own_lambda_burn = s.own_lambda_burn,
            deps = deps,
            closures = facts,
        }
        const view = copy.key.as_view()
        by_key.set(view, s.id)
        specs.set(s.id, copy)
    }
    return SpecializationRegistry {
        by_key = by_key,
        specs = specs,
        next_id = self.next_id,
        gen = self.gen,
        allocator = allocator,
    }
}

test "specialization keys separate same-named types from different modules" {
    // Two modules may each declare a `Binding`; the key must tell their specializations apart.
    // Nominals are keyed by registry id, which is unique per declaration - keying by a type's short
    // name is what made the reference compiler fuse two specializations into one and emit a call to
    // a symbol nothing defined (docs/known-issues.md).
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

test "a carried copy holds every live entry under its key" {
    let reg = specialization_registry()
    defer reg.deinit()
    let a = reg.register(probe_spec(1 as u32, "a"))
    let b = reg.register(probe_spec(2 as u32, "b"))
    let copy = reg.carried_copy()
    defer copy.deinit()
    assert_eq(copy.len(), 2 as usize, "both entries copied")
    assert_eq(copy.next_id, reg.next_id, "numbering carries")
    assert_eq(copy.get(a).function_id, 1 as u32, "the entry answers at its id")
    assert_true(copy.lookup(reg.get(b).key.as_view()).is_some(), "and under its key")
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
    return new_specialization(function_id, key_for(&it, function_id, &no_params, ret), name, "m",
        decl, no_params, ret, inference_results())
}

// Replace a specialization's concrete signature - used when a signature that entered instantiation
// with callable-slot vars (RFC-014 lambdas through `$F`) settled during the body re-check.
pub fn set_signature(self: &SpecializationRegistry, id: SpecId, params: List(Ty), ret: Ty) {
    let s = self.specs.get_ref(id).unwrap()
    s.concrete_params.deinit()
    s.concrete_params = params
    s.concrete_return = ret
}

// Re-key a specialization under its settled signature. Returns false - and frees `new_key` - when a
// DIFFERENT spec already owns that key: the caller's spec stays registered under its provisional
// key and its emission dedups by symbol.
pub fn rekey(self: &SpecializationRegistry, id: SpecId, new_key: OwnedString) bool {
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
