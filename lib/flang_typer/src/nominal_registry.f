// Nominal type registry — struct and enum declarations indexed by FQN.
//
// Distinct from the C# `TypeRegistry`: struct fields and enum variants
// have their own first-class shapes (`StructDef` / `EnumDef`) instead
// of being lumped into a `FieldsOrVariants` list discriminated by an
// enum `Kind`. Payload-less enum variants carry an empty `payloads`
// list — no `void` sentinel.
//
// Lookups return `RegLookup` instead of `Option` so the caller can
// distinguish "not found" from "found but not visible" — that
// distinction drives a better diagnostic ("type exists in module X
// but is not imported here").

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.string_builder
import flang_core.span
import flang_typer.type
import flang_typer.visibility

// One enum variant. `payloads` is empty for nullary variants.
pub type VariantDef = struct {
    name: String
    payloads: List(Ty)
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
// module is outside the caller's visibility scope — used to emit a
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
    defs: List(NominalDef)              // indexed by NominalId
    by_fqn: Dict(String, NominalId)
    // FQN strings live on the registry. `def.fqn` and `by_fqn` keys are
    // views into the heap buffers owned here. The buffers themselves
    // are heap-allocated by `OwnedString` and do not move when the list
    // re-allocates, so the views stay valid for the registry's life.
    owned_fqns: List(OwnedString)
    allocator: &Allocator
}

pub fn nominal_registry(allocator: &Allocator? = null) NominalRegistry {
    let alloc = allocator.or_global()
    let defs: List(NominalDef) = list(0, alloc)
    let by_fqn: Dict(String, NominalId) = dict(alloc)
    let owned_fqns: List(OwnedString) = list(0, alloc)
    return .{
        defs = defs,
        by_fqn = by_fqn,
        owned_fqns = owned_fqns,
        allocator = alloc,
    }
}

pub fn deinit(self: &NominalRegistry) {
    self.defs.deinit()
    self.by_fqn.deinit()
    for i in 0..self.owned_fqns.len {
        let s = &self.owned_fqns[i]
        s.deinit()
    }
    self.owned_fqns.deinit()
}

// Register a new nominal. The caller transfers ownership of `fqn_owned`
// to the registry — the heap buffer keeps the `String` views in both
// `def.fqn` and `by_fqn` stable for the registry's lifetime. The `fqn`
// field on `def` is overwritten with the stable view, so the caller can
// pass a placeholder there.
//
// Caller is responsible for checking duplicates first — registering an
// FQN twice overwrites the index and leaks the previous definition.
pub fn register(self: &NominalRegistry, def: NominalDef, fqn_owned: OwnedString) NominalId {
    let id: NominalId = self.defs.len as u32
    let idx = self.owned_fqns.len
    self.owned_fqns.push(fqn_owned)
    let stable: String = self.owned_fqns[idx].as_view()
    let fixed = with_fqn(def, stable)
    self.defs.push(fixed)
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

pub fn contains(self: &NominalRegistry, fqn: String) bool {
    return self.by_fqn.contains(fqn)
}

pub fn get(self: &NominalRegistry, id: NominalId) &NominalDef {
    return &self.defs[id as usize]
}

// FQN-only lookup, no visibility scope. Used by template expansion and
// downstream phases that have already accepted the symbol.
pub fn lookup_fqn(self: &NominalRegistry, fqn: String) NominalId? {
    return self.by_fqn.get(fqn)
}

// Resolve a name in the caller's visibility scope. `name` may be:
//   - a full FQN (`mod.sub.Type`) — bypasses visibility,
//   - a current-module-prefixed name (`Type` resolved against `vis.current_module`),
//   - a bare short name — scanned across every FQN with the matching
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
