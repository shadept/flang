// Function registry - overload sets indexed by name.
//
// `FunctionScheme` carries the polymorphic signature plus the metadata the resolver needs (origin
// module, public visibility, deprecation, foreign flag). The signature itself is a `Scheme` whose
// body is a `Func(FunctionTy)` so quantifier handling reuses the same generalise / specialise
// machinery as let-generalisation.
//
// Lookups mirror `nominal_registry`: same `RegLookup`-style result, same `Visibility`-driven
// short-name filtering, FQN bypass.

import std.allocator
import std.dict
import std.list
import std.option
import std.set
import std.string
import std.test
import flang_core.span
import flang_typer.type
import flang_typer.scheme
import flang_typer.visibility

pub type FunctionScheme = struct {
    name: String
    signature: Scheme
    module: String? // null for synthesised (lambda host) fns
    is_pub: bool
    is_foreign: bool
    // Call-site arity window: params beyond `required_params` are defaulted (or the variadic tail)
    // and may be omitted.
    required_params: usize
    has_variadic: bool
    decl_span: SourceSpan
    deprecation: String?
    // The id consumers cite when resolving a call. Stable across a single compilation.
    id: u32
    // A retired entry keeps its slot and id but stops resolving: its module's signature pass is
    // running again, and a matching re-registration reclaims the slot in place so overload order
    // and ids match a registry built from cold. Entries that stay retired once the pass is over
    // name removed declarations - `purge_retired` drops them.
    retired: bool
}

// Does NOT free `signature.quantified`, the entry's one piece of heap, and so leaks it. `FnLookup`
// hands a caller a COPY of the candidate list, every overload resolution drops that copy, and a
// scheme that freed on drop would take the registry's set with it. Freeing here means making lookup
// hand back a borrow first. See docs/known-issues.md on scheme ownership.
pub fn deinit(self: &FunctionScheme) {}

// Multi-payload variants where one payload is a generic-typed value (`List(FunctionScheme)`)
// confuse the FLang parser - the comma inside the generic argument list is ambiguous with the
// variant-payload separator. Wrapping the multi-payload case in its own struct keeps the variant
// payload list unambiguous.
pub type FnLookHiddenInfo = struct {
    candidates: List(FunctionScheme)
    module: String
}

pub type FnLookup = enum {
    FnLookFound(List(FunctionScheme))
    FnLookHidden(FnLookHiddenInfo)
    FnLookMissing
}

pub type FunctionRegistry = struct {
    // name → overload set. The order schemes were registered in is
    // preserved so overload resolution scoring is deterministic.
    by_name: Dict(String, List(FunctionScheme))
    next_id: u32
    // Set when a reclaim overwrote a slot with a scheme that differs from what the slot held -
    // resolution against the registry can now pick differently, so results that baked earlier
    // resolutions (RFC-022 5d carried bodies) are stale. Signature bodies are interned handles, and
    // the variable stream is position-stable across demands, so handle equality is scheme equality;
    // a spurious inequality from an upstream stream shift only over-invalidates.
    changed: bool
    allocator: &Allocator?
}

pub fn function_registry(allocator: &Allocator? = null) FunctionRegistry {
    let by_name: Dict(String, List(FunctionScheme)) = dict(allocator)
    return .{ by_name = by_name, next_id = 0u32, changed = false, allocator = allocator }
}

pub fn deinit(self: &FunctionRegistry) {
    self.by_name.deinit()
}

// Register `scheme` under `scheme.name`. Returns the assigned id. Duplicate-signature detection is
// the caller's responsibility - the registry stores whatever is pushed.
//
// A retired slot under the same name and module is reclaimed in place - same list position, same id
// - so a module whose declarations register again after `retire_module` rebuilds exactly the
// entries it had. Registration order within one module and name is source order both times, which
// is what pairs each declaration with its own slot.
pub fn register(self: &FunctionRegistry, scheme: FunctionScheme) u32 {
    if self.by_name.get_ref(scheme.name).is_none() {
        let fresh: List(FunctionScheme) = list(1, self.allocator)
        self.by_name.set(scheme.name, fresh)
    }
    // In place through the stored list: the get-copy-push-set dance both leaked and double-freed
    // once `Dict.set` started deiniting overwritten values (the copy shares the stored buffer).
    let lst = self.by_name.get_ref(scheme.name).unwrap()
    for j in 0..lst.len {
        if lst[j].retired and same_module(lst[j].module, scheme.module) {
            const id = lst[j].id
            if !reclaim_equal(&lst[j], &scheme) {
                self.changed = true
            }
            lst[j] = with_id(&scheme, id)
            return id
        }
    }
    let id = self.next_id
    self.next_id = id + 1u32
    lst.push(with_id(&scheme, id))
    return id
}

fn with_id(scheme: &FunctionScheme, id: u32) FunctionScheme {
    return FunctionScheme {
        name = scheme.name,
        signature = scheme.signature,
        module = scheme.module,
        is_pub = scheme.is_pub,
        is_foreign = scheme.is_foreign,
        required_params = scheme.required_params,
        has_variadic = scheme.has_variadic,
        decl_span = scheme.decl_span,
        deprecation = scheme.deprecation,
        id = id,
        retired = false,
    }
}

// Whether a re-registration says the same thing the retired slot said, on every field resolution or
// a caller's cached diagnostics can observe. `decl_span` is deliberately left out - a declaration
// that only moved resolves identically.
fn reclaim_equal(old: &FunctionScheme, new: &FunctionScheme) bool {
    return old.signature.body == new.signature.body
        and old.signature.quantified.len() == new.signature.quantified.len()
        and old.is_pub == new.is_pub and old.is_foreign == new.is_foreign
        and old.required_params == new.required_params and old.has_variadic == new.has_variadic
        and same_deprecation(old.deprecation, new.deprecation)
}

fn same_deprecation(a: String?, b: String?) bool {
    return a match {
        Some(am) => b match {
            Some(bm) => am == bm
            None => false
        }
        None => b.is_none()
    }
}

fn same_module(a: String?, b: String?) bool {
    return a match {
        Some(am) => b match {
            Some(bm) => am == bm
            None => false
        }
        None => b.is_none()
    }
}

// Arm the change flag for a fresh demand's signature phase.
pub fn reset_changed(self: &FunctionRegistry) {
    self.changed = false
}

// The registered names, snapshotted so a caller can mutate the lists behind them while it walks.
fn key_list(self: &FunctionRegistry) List(String) {
    let names: List(String) = list(self.by_name.len(), self.allocator)
    for entry in self.by_name {
        names.push(entry.key)
    }
    return names
}

// Take module `module`'s entries out of resolution so its signature pass can register them again.
// Slots and ids stay in place for `register` to reclaim.
pub fn retire_module(self: &FunctionRegistry, module: String) {
    let names = key_list(self)
    defer names.deinit()
    for name in names {
        let lst = self.by_name.get_ref(name).unwrap()
        for j in 0..lst.len {
            if lst[j].retired {
                continue
            }
            if !same_module(lst[j].module, Some(module)) {
                continue
            }
            let dead = lst[j]
            dead.retired = true
            lst[j] = dead
        }
    }
}

// Drop every entry still retired - declarations whose sources no longer register them. Returns the
// dropped ids so the caller can clear its own id-keyed side tables. Live entries keep their
// positions.
pub fn purge_retired(self: &FunctionRegistry) List(u32) {
    let dropped: List(u32) = list(0, self.allocator)
    let names = key_list(self)
    defer names.deinit()
    for name in names {
        let lst = self.by_name.get_ref(name).unwrap()
        let keep: List(FunctionScheme) = list(lst.len, self.allocator)
        let any_dead = false
        for j in 0..lst.len {
            if lst[j].retired {
                dropped.push(lst[j].id)
                any_dead = true
                continue
            }
            keep.push(lst[j])
        }
        if !any_dead {
            keep.deinit()
            continue
        }
        lst.clear()
        lst.push_all(keep.as_slice())
        keep.deinit()
    }
    return dropped
}

// A copy of every live entry at the id and list position it holds, for the checker to carry into
// the next demand while the snapshot keeps the original. Entry structs are copied by value: names,
// modules and deprecations are views into buffers that outlive both registries, and the quantifier
// sets are shared read-only (nothing ever frees a scheme's set).
pub fn carried_copy(self: &FunctionRegistry, allocator: &Allocator? = null) FunctionRegistry {
    let out = function_registry(allocator)
    fill_fn_carried(&out, self, allocator)
    return out
}

fn fill_fn_carried(out: &FunctionRegistry, src: &FunctionRegistry, allocator: &Allocator?) {
    for entry in src.by_name {
        let overloads: List(FunctionScheme) = entry.value
        let cl: List(FunctionScheme) = list(overloads.len, allocator)
        for &f in overloads {
            cl.push(f.*)
        }
        out.by_name.set(entry.key, cl)
    }
    out.next_id = src.next_id
}

// The live scheme registered under `id`, or null. Linear over the overload sets; fine for
// per-request consumers (the LSP), cache if ever on a hot path.
pub fn find_by_id(self: &FunctionRegistry, id: u32) &FunctionScheme? {
    for e in self.by_name {
        for i in 0..e.value.len {
            if e.value[i].id == id and !e.value[i].retired {
                return e.value.get_ref(i)
            }
        }
    }
    return null
}

// Resolve `name` in the caller's visibility scope. Returns the candidates that are reachable; if
// nothing is reachable but some hidden overloads exist, returns one of them along with its module
// for the diagnostic hint.
pub fn lookup(self: &FunctionRegistry, name: String, vis: &Visibility) FnLookup {
    let overloads_opt = self.by_name.get(name)
    if overloads_opt.is_none() {
        return FnLookup.FnLookMissing
    }
    let overloads = overloads_opt.unwrap()

    let visible: List(FunctionScheme) = list(0, self.allocator)
    let hidden_module: String? = null
    let hidden_at: usize = 0
    for j in 0..overloads.len {
        let f = &overloads[j]
        // A retired entry is mid-re-registration (or removed) - it does not resolve.
        if f.retired {
            continue
        }
        if visibility_for(f, vis) {
            visible.push(f.*)
        } else {
            if hidden_module.is_none() {
                f.module match {
                    Some(m) => {
                        hidden_module = Some(m)
                        hidden_at = j
                    }
                    None => {}
                }
            }
        }
    }
    if visible.len > 0 {
        return FnLookup.FnLookFound(visible)
    }
    if hidden_module.is_some() {
        let one: List(FunctionScheme) = list(1, self.allocator)
        one.push(overloads[hidden_at])
        return FnLookup.FnLookHidden(FnLookHiddenInfo {
            candidates = one,
            module = hidden_module.unwrap(),
        })
    }
    return FnLookup.FnLookMissing
}

fn visibility_for(f: &FunctionScheme, vis: &Visibility) bool {
    // Synthesised functions (no module) are always visible.
    f.module match {
        None => return true
        Some(m) => {
            vis.current_module match {
                Some(cur) => if cur == m { return true }
                None => {}
            }
            // A foreign fn names a global link-time symbol, so it is not module-scoped at all: it
            // resolves from anywhere in the program without an import. Mirrors the reference
            // compiler (FunctionRegistry.cs, "extern C symbols are globally linkable").
            if f.is_foreign {
                return true
            }
            if !f.is_pub {
                return false
            }
            return vis.visible.contains(m)
        }
    }
}

// Tests

fn probe_scheme(name: String, module: String) FunctionScheme {
    return FunctionScheme {
        name = name,
        signature = mono(prim_of(PrimitiveKind.I32)),
        module = Some(module),
        is_pub = true,
        is_foreign = false,
        required_params = 0usize,
        has_variadic = false,
        decl_span = none_span(),
        deprecation = null,
        id = 0u32,
        retired = false,
    }
}

test "a retired entry stops resolving until it is registered again" {
    let reg = function_registry()
    defer reg.deinit()
    const a = reg.register(probe_scheme("f", "m"))
    reg.retire_module("m")
    let scope: Set(String) = set()
    let vis = visibility(Some("m"), scope)
    defer vis.visible.deinit()
    let missing = reg.lookup("f", &vis) match {
        FnLookMissing => true
        _ => false
    }
    assert_true(missing, "a retired entry is invisible to lookup")

    const again = reg.register(probe_scheme("f", "m"))
    assert_eq(again, a, "re-registration reclaims the retired slot's id")
    let found = reg.lookup("f", &vis) match {
        FnLookFound(c) => {
            const n = c.len
            c.deinit()
            n
        }
        _ => 0 as usize
    }
    assert_eq(found, 1 as usize, "and the entry resolves again")
}

test "reclaim keeps overload order and other modules' entries in place" {
    let reg = function_registry()
    defer reg.deinit()
    const a = reg.register(probe_scheme("f", "m1"))
    const b = reg.register(probe_scheme("f", "m2"))
    const c = reg.register(probe_scheme("f", "m1"))
    reg.retire_module("m1")
    const a2 = reg.register(probe_scheme("f", "m1"))
    const c2 = reg.register(probe_scheme("f", "m1"))
    assert_eq(a2, a, "the first declaration takes the first retired slot")
    assert_eq(c2, c, "the second takes the second")
    let lst = reg.by_name.get_ref("f").unwrap()
    assert_eq(lst[0].id, a, "positions are unchanged")
    assert_eq(lst[1].id, b, "the untouched module's entry sits where it was")
    assert_eq(lst[2].id, c, "positions are unchanged")
    assert_eq(reg.next_id, 3u32, "no new id was handed out")
}

test "purge drops what stayed retired and reports the ids" {
    let reg = function_registry()
    defer reg.deinit()
    const _a = reg.register(probe_scheme("f", "m"))
    const b = reg.register(probe_scheme("g", "m"))
    reg.retire_module("m")
    const _a2 = reg.register(probe_scheme("f", "m"))
    let dropped = reg.purge_retired()
    defer dropped.deinit()
    assert_eq(dropped.len, 1 as usize, "the unclaimed retirement is dropped")
    assert_eq(dropped[0], b, "and named by id")
    let vis = open()
    defer vis.visible.deinit()
    let gone = reg.lookup("g", &vis) match {
        FnLookMissing => true
        _ => false
    }
    assert_true(gone, "the removed declaration stops resolving")
    const d = reg.register(probe_scheme("h", "m"))
    assert_eq(d, 2u32, "a purged id is never handed out again")
}

test "a carried copy keeps ids, positions and the id counter" {
    let reg = function_registry()
    defer reg.deinit()
    const a = reg.register(probe_scheme("f", "m1"))
    const b = reg.register(probe_scheme("f", "m2"))
    let next = reg.carried_copy()
    defer next.deinit()
    assert_eq(next.next_id, reg.next_id, "the id counter carries")
    let lst = next.by_name.get_ref("f").unwrap()
    assert_eq(lst.len, 2 as usize, "both overloads carried")
    assert_eq(lst[0].id, a, "in the order they were registered")
    assert_eq(lst[1].id, b, "in the order they were registered")
}
