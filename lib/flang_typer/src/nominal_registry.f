// Nominal type registry - struct and enum declarations indexed by FQN.
//
// Distinct from the C# `TypeRegistry`: struct fields and enum variants
// have their own first-class shapes (`StructDef` / `EnumDef`) instead
// of being lumped into a `FieldsOrVariants` list discriminated by an
// enum `Kind`. Payload-less enum variants carry an empty `payloads`
// list - no `void` sentinel.
//
// Lookups return `RegLookup` instead of `Option` so the caller can
// distinguish "not found" from "found but not visible" - that
// distinction drives a better diagnostic ("type exists in module X
// but is not imported here").

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.string_builder
import std.test
import flang_core.span
import flang_typer.type
import flang_typer.visibility

// One enum variant. `payloads` is empty for nullary variants.
// `decl_span` locates the variant's own declaration inside the enum body,
// and is `none_span()` for synthesized variants.
pub type VariantDef = struct {
    name: String
    payloads: List(Ty)
    decl_span: SourceSpan
}

pub type StructDef = struct {
    fqn: String
    module: String
    is_pub: bool
    type_params: List(VarId)
    fields: List(Field)
    decl_span: SourceSpan
    deprecation: String?
    is_simd: bool
    is_foreign: bool
}

pub type EnumDef = struct {
    fqn: String
    module: String
    is_pub: bool
    type_params: List(VarId)
    variants: List(VariantDef)
    // Naked enums (every variant payload-less, explicit integer tags).
    // `null` for standard tagged-union enums.
    tag_values: Dict(String, i64)?
    decl_span: SourceSpan
    deprecation: String?
}

pub type NominalDef = enum {
    NomStruct(StructDef)
    NomEnum(EnumDef)
}

// Result of looking up a name in the registry. `NomLookFound` returns
// the index; `NomLookHidden` means the entry exists but its defining
// module is outside the caller's visibility scope - used to emit a
// "did you forget `import X`?" hint. `NomLookMissing` means no entry
// by that name exists anywhere.
pub type NomHiddenInfo = struct {
    id: NominalId
    module: String
}

pub type NomLookup = enum {
    NomLookFound(NominalId)
    NomLookHidden(NomHiddenInfo)
    NomLookMissing
}

pub type NominalRegistry = struct {
    // Keyed by id, not positional. Ids come from `next_id` and are never
    // reused, so evicting an entry leaves a hole instead of renumbering
    // every id after it - the nominal type nodes already baked into
    // other results stay valid.
    defs: Dict(NominalId, NominalDef)
    next_id: NominalId
    by_fqn: Dict(String, NominalId)
    // FQN strings live on the registry. `def.fqn` and `by_fqn` keys are
    // views into the heap buffers owned here. The buffers themselves
    // are heap-allocated by `OwnedString` and do not move when the list
    // re-allocates, so the views stay valid for the registry's life.
    owned_fqns: List(OwnedString)
    allocator: &Allocator?
}

pub fn nominal_registry(allocator: &Allocator? = null) NominalRegistry {
    let defs: Dict(NominalId, NominalDef) = dict(allocator)
    let by_fqn: Dict(String, NominalId) = dict(allocator)
    let owned_fqns: List(OwnedString) = list(0, allocator)
    return .{
        defs = defs,
        next_id = 0 as NominalId,
        by_fqn = by_fqn,
        owned_fqns = owned_fqns,
        allocator = allocator,
    }
}

pub fn deinit(self: &NominalRegistry) {
    self.defs.deinit()
    self.by_fqn.deinit()
    self.owned_fqns.deinit()
}

// Register a new nominal. The caller transfers ownership of `fqn_owned`
// to the registry - the heap buffer keeps the `String` views in both
// `def.fqn` and `by_fqn` stable for the registry's lifetime. The `fqn`
// field on `def` is overwritten with the stable view, so the caller can
// pass a placeholder there.
//
// Caller is responsible for checking duplicates first - registering an
// FQN twice overwrites the index and leaks the previous definition.
pub fn register(self: &NominalRegistry, def: NominalDef, fqn_owned: OwnedString) NominalId {
    let id: NominalId = self.next_id
    self.next_id = id + 1
    let idx = self.owned_fqns.len
    self.owned_fqns.push(fqn_owned)
    let stable: String = self.owned_fqns[idx].as_view()
    let fixed = with_fqn(def, stable)
    self.defs.set(id, fixed)
    self.by_fqn.set(stable, id)
    return id
}

// Replace the fqn field on a NominalDef with a stable view. Used by
// `register` to repoint def.fqn from a caller-temporary view to the
// view owned by `self.owned_fqns`.
fn with_fqn(def: NominalDef, new_fqn: String) NominalDef {
    return def match {
        NomStruct(s) => NominalDef.NomStruct(StructDef {
            fqn = new_fqn,
            module = s.module,
            is_pub = s.is_pub,
            type_params = s.type_params,
            fields = s.fields,
            decl_span = s.decl_span,
            deprecation = s.deprecation,
            is_simd = s.is_simd,
            is_foreign = s.is_foreign,
        }),
        NomEnum(e) => NominalDef.NomEnum(EnumDef {
            fqn = new_fqn,
            module = e.module,
            is_pub = e.is_pub,
            type_params = e.type_params,
            variants = e.variants,
            tag_values = e.tag_values,
            decl_span = e.decl_span,
            deprecation = e.deprecation,
        }),
    }
}

// Re-register a definition under an id the registry handed out before, using
// the FQN view it already owns. `next_id` is untouched, so an id retired by
// `evict` and put back here keeps naming the same declaration.
pub fn register_at(self: &NominalRegistry, id: NominalId, def: NominalDef, fqn_stable: String) {
    let fixed = with_fqn(def, fqn_stable)
    self.defs.set(id, fixed)
    self.by_fqn.set(fqn_stable, id)
}

// The definitions below `mark`, stripped back to what a name-collection pass
// produces: identity, visibility, span and directive flags, with the resolved
// body dropped. Ids, FQNs and `next_id` carry over, so a check starting from
// the copy hands out exactly the ids it would have from an empty registry.
//
// A body references type variables of the engine that resolved it, and the
// engine does not outlive its check, so the body stays behind.
pub fn placeholders_below(self: &NominalRegistry, mark: NominalId,
        allocator: &Allocator? = null) NominalRegistry {
    let out = nominal_registry(allocator)
    fill_placeholders(&out, self, mark, allocator)
    return out
}

fn fill_placeholders(out: &NominalRegistry, src: &NominalRegistry, mark: NominalId,
        allocator: &Allocator?) {
    for i in 0..(mark as usize) {
        const id = i as NominalId
        const found = src.defs.get_ref(id)
        if found.is_none() { continue }
        const idx = out.owned_fqns.len
        out.owned_fqns.push(from_view(nominal_fqn(found.unwrap()), allocator))
        out.register_at(id, placeholder_of(found.unwrap(), allocator), out.owned_fqns[idx].as_view())
    }
    out.next_id = mark
}

// One definition with its body emptied. The field and variant lists are fresh
// and empty; the source they were resolved from is what fills them again.
fn placeholder_of(def: &NominalDef, allocator: &Allocator?) NominalDef {
    return def.* match {
        NomStruct(s) => NominalDef.NomStruct(StructDef {
            fqn = s.fqn,
            module = s.module,
            is_pub = s.is_pub,
            type_params = list(0, allocator),
            fields = list(0, allocator),
            decl_span = s.decl_span,
            deprecation = s.deprecation,
            is_simd = s.is_simd,
            is_foreign = s.is_foreign,
        }),
        NomEnum(e) => NominalDef.NomEnum(EnumDef {
            fqn = e.fqn,
            module = e.module,
            is_pub = e.is_pub,
            type_params = list(0, allocator),
            variants = list(0, allocator),
            tag_values = null,
            decl_span = e.decl_span,
            deprecation = e.deprecation,
        }),
    }
}

pub fn contains(self: &NominalRegistry, fqn: String) bool {
    return self.by_fqn.contains(fqn)
}

// The definition at `id`. Panics on an id that was never registered or
// has been evicted; callers holding a possibly-stale id use `find`.
pub fn get(self: &NominalRegistry, id: NominalId) &NominalDef {
    return self.defs.get_ref(id).unwrap()
}

// The definition at `id`, or null when the id names a hole.
pub fn find(self: &NominalRegistry, id: NominalId) &NominalDef? {
    return self.defs.get_ref(id)
}

// Live definitions. Not an id bound - iterate `0..next_id` and skip the
// holes for that.
pub fn len(self: &NominalRegistry) usize {
    return self.defs.len()
}

// Overwrite the definition at `id` in place. The replaced value is NOT
// deinited: callers rebuild a def from the old one's field and type-param
// lists and keep owning them.
pub fn put(self: &NominalRegistry, id: NominalId, def: NominalDef) {
    let slot = self.defs.get_ref(id).unwrap()
    slot.* = def
}

// Drop the definition at `id` and its FQN mapping. The id is retired, not
// recycled: `find` reports the hole rather than resolving to a neighbour.
pub fn evict(self: &NominalRegistry, id: NominalId) {
    let found = self.defs.get_ref(id)
    if found.is_none() { return }
    let _fqn = self.by_fqn.remove(nominal_fqn(found.unwrap()))
    let _dropped = self.defs.remove(id)
}

// FQN-only lookup, no visibility scope. Used by template expansion and
// downstream phases that have already accepted the symbol.
pub fn lookup_fqn(self: &NominalRegistry, fqn: String) NominalId? {
    return self.by_fqn.get(fqn)
}

// Resolve a name in the caller's visibility scope. `name` may be:
//   - a full FQN (`mod.sub.Type`) - bypasses visibility,
//   - a current-module-prefixed name (`Type` resolved against `vis.current_module`),
//   - a bare short name - scanned across every FQN with the matching
//     short name, restricted to visible modules.
pub fn lookup(self: &NominalRegistry, name: String, vis: &Visibility) NomLookup {
    // Direct FQN hit.
    let direct = self.by_fqn.get(name)
    if direct.is_some() { return NomLookup.NomLookFound(direct.unwrap()) }

    // Current-module prefix.
    if vis.current_module.is_some() {
        let cur = vis.current_module.unwrap()
        let qualified_owned = $"{cur}.{name}"
        let q = self.by_fqn.get(qualified_owned.as_view())
        qualified_owned.deinit()
        if q.is_some() { return NomLookup.NomLookFound(q.unwrap()) }
    }

    // Short-name scan with visibility filter. First visible hit wins;
    // a hidden hit is remembered so we can return it as a hint when
    // nothing visible matches.
    let hidden_id: NominalId? = null
    let hidden_module: String? = null
    for entry in self.by_fqn {
        let fqn = entry.key
        let id = entry.value
        let dot = last_dot(fqn)
        let short = short_name_of(fqn, dot)
        if short != name { continue }
        let module = module_of(fqn, dot)
        if vis.allows(module) { return NomLookup.NomLookFound(id) }
        if hidden_id.is_none() {
            hidden_id = Some(id)
            hidden_module = Some(module)
        }
    }
    if hidden_id.is_some() {
        return NomLookup.NomLookHidden(NomHiddenInfo {
            id = hidden_id.unwrap(),
            module = hidden_module.unwrap(),
        })
    }
    return NomLookup.NomLookMissing
}

// First visible enum declaring a variant `name` with exactly `arity`
// payloads. Registration order breaks ties - qualify with the enum name
// when two visible enums share a variant shape.
// ponytail: linear scan over every def per call; index variant names if
// checker profiles flag it.
pub fn lookup_variant(self: &NominalRegistry, name: String, arity: usize, vis: &Visibility) NominalId? {
    for i in 0..(self.next_id as usize) {
        let found = self.defs.get_ref(i as NominalId)
        if found.is_none() { continue }
        let d = found.unwrap()
        let ed = d.* match {
            NomEnum(e) => Some(e),
            _ => null,
        }
        if ed.is_none() { continue }
        let e = ed.unwrap()
        if !vis.allows(e.module) { continue }
        for &v in e.variants {
            if v.name == name and v.payloads.len == arity {
                return Some(i as u32)
            }
        }
    }
    return null
}

// ─────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────

// Index of the final `.` in an FQN, or -1 when the name is unqualified.
pub fn last_dot(s: String) isize {
    let i: isize = (s.len as isize) - 1
    loop {
        if i < 0 { break }
        if s[i as usize] == 46u8 { return i }   // '.' = 46
        i = i - 1
    }
    return -1
}

// The short (module-less) name of an FQN, given its `last_dot` index.
pub fn short_name_of(fqn: String, dot: isize) String {
    if dot < 0 { return fqn }
    return fqn[((dot as usize) + 1)..fqn.len]
}

// The owning module prefix of an FQN, given its `last_dot` index; empty
// when the name is unqualified.
pub fn module_of(fqn: String, dot: isize) String {
    if dot < 0 { return "" }
    return fqn[0..(dot as usize)]
}

pub fn nominal_fqn(def: &NominalDef) String {
    return def.* match {
        NomStruct(s) => s.fqn,
        NomEnum(e) => e.fqn,
    }
}

pub fn nominal_module(def: &NominalDef) String {
    return def.* match {
        NomStruct(s) => s.module,
        NomEnum(e) => e.module,
    }
}

pub fn is_pub(def: &NominalDef) bool {
    return def.* match {
        NomStruct(s) => s.is_pub,
        NomEnum(e) => e.is_pub,
    }
}

// Whether every variant of the enum at `id` is payload-less - the shape
// that gets builtin tag-compare `==`/`!=` (checker) and tag-compare
// lowering (driver). False for structs.
pub fn enum_payloadless(self: &NominalRegistry, id: NominalId) bool {
    return self.get(id).* match {
        NomEnum(e) => {
            for i in 0..e.variants.len {
                if e.variants[i].payloads.len > 0 { return false }
            }
            true
        },
        _ => false,
    }
}

test "an evicted nominal leaves a hole and never recycles its id" {
    let reg = nominal_registry()
    defer reg.deinit()
    let a = reg.register(NominalDef.NomStruct(probe_struct()), $"m.A")
    let b = reg.register(NominalDef.NomStruct(probe_struct()), $"m.B")
    let c = reg.register(NominalDef.NomStruct(probe_struct()), $"m.C")
    assert_eq(a, 0 as NominalId, "ids start at zero")
    assert_eq(c, 2 as NominalId, "ids are handed out in registration order")

    reg.evict(b)
    assert_true(reg.find(b).is_none(), "the evicted id names a hole")
    assert_true(reg.lookup_fqn("m.B").is_none(), "the evicted fqn stops resolving")
    assert_eq(nominal_fqn(reg.get(c)), "m.C", "the id past the hole still names its own def")
    assert_eq(reg.len(), 2 as usize, "a hole is not a live entry")

    let d = reg.register(NominalDef.NomStruct(probe_struct()), $"m.D")
    assert_eq(d, 3 as NominalId, "a retired id is never handed out again")
}

test "placeholders keep their ids and drop their bodies" {
    let reg = nominal_registry()
    defer reg.deinit()
    const a = reg.register(NominalDef.NomStruct(probe_struct()), $"m.A")
    const b = reg.register(NominalDef.NomStruct(probe_struct()), $"m.B")
    reg.evict(a)
    // Past the mark: what a check mints as it runs, and must mint again.
    const anon = reg.register(NominalDef.NomStruct(probe_struct()), $"__anon_2")
    assert_eq(anon, 2 as NominalId, "the anonymous record sits above the declarations")

    // Give `m.B` a body, as `resolve_nominal_bodies` would.
    let fields: List(Field) = list(1)
    fields.push(Field { name = "x", ty = prim_of(PrimitiveKind.I32), decl_span = none_span() })
    let bd = reg.get(b).* match { NomStruct(s) => s, _ => probe_struct() }
    bd.fields = fields
    reg.put(b, NominalDef.NomStruct(bd))

    let next = reg.placeholders_below(2 as NominalId)
    defer next.deinit()
    assert_eq(next.len(), 1 as usize, "the evicted id stays a hole, the anonymous one is left behind")
    assert_eq(next.lookup_fqn("m.B").unwrap(), b, "a surviving declaration keeps its id")
    assert_eq(next.next_id, 2 as NominalId, "ids resume at the mark, so the next check mints the same ones")
    const body = next.get(b).* match { NomStruct(s) => s.fields.len, _ => 99 as usize }
    assert_eq(body, 0 as usize, "the resolved body does not come across")
}

test "a retired id goes back where it was" {
    let reg = nominal_registry()
    defer reg.deinit()
    const a = reg.register(NominalDef.NomStruct(probe_struct()), $"m.A")
    const b = reg.register(NominalDef.NomStruct(probe_struct()), $"m.B")
    const fqn = nominal_fqn(reg.get(a))
    reg.evict(a)
    reg.register_at(a, NominalDef.NomStruct(probe_struct()), fqn)
    assert_eq(reg.lookup_fqn("m.A").unwrap(), a, "the declaration resolves to the id it had")
    assert_eq(reg.next_id, b + 1, "putting one back does not hand out a new id")
}

fn probe_struct() StructDef {
    let no_params: List(VarId) = list(0)
    let no_fields: List(Field) = list(0)
    return StructDef {
        fqn = "", module = "m", is_pub = true,
        type_params = no_params, fields = no_fields,
        decl_span = none_span(), deprecation = null,
        is_simd = false, is_foreign = false,
    }
}
