// Function registry — overload sets indexed by name.
//
// `FunctionScheme` carries the polymorphic signature plus the
// metadata the resolver needs (origin module, public visibility,
// deprecation, foreign flag). The signature itself is a `Scheme`
// whose body is a `Func(FunctionTy)` so quantifier handling reuses
// the same generalise / specialise machinery as let-generalisation.
//
// Lookups mirror `nominal_registry`: same `RegLookup`-style result,
// same `Visibility`-driven short-name filtering, FQN bypass.

import std.allocator
import std.dict
import std.list
import std.option
import std.set
import std.string
import flang_core.span
import flang_typer.type
import flang_typer.scheme
import flang_typer.visibility

pub type FunctionScheme = struct {
    name: String
    signature: Scheme
    module: String?           // null for synthesised (lambda host) fns
    is_pub: bool
    is_foreign: bool
    decl_span: SourceSpan
    deprecation: String?
    // The id consumers cite when resolving a call. Stable across a
    // single compilation.
    id: u32
}

// Multi-payload variants where one payload is a generic-typed value
// (`List(FunctionScheme)`) confuse the FLang parser — the comma inside
// the generic argument list is ambiguous with the variant-payload
// separator. Wrapping the multi-payload case in its own struct keeps
// the variant payload list unambiguous.
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
    allocator: &Allocator
}

pub fn function_registry(allocator: &Allocator? = null) FunctionRegistry {
    let alloc = allocator.or_global()
    let by_name: Dict(String, List(FunctionScheme)) = dict(alloc)
    return .{ by_name = by_name, next_id = 0u32, allocator = alloc }
}

pub fn deinit(self: &FunctionRegistry) {
    // Each overload-set list owns its buffer.
    for entry in self.by_name {
        let lst = entry.value
        let l = lst; l.deinit()
    }
    self.by_name.deinit()
}

// Register `scheme` under `scheme.name`. Returns the assigned id.
// Duplicate-signature detection is the caller's responsibility — the
// registry stores whatever is pushed.
pub fn register(self: &FunctionRegistry, scheme: FunctionScheme) u32 {
    let id = self.next_id
    self.next_id = id + 1u32
    let with_id = FunctionScheme {
        name = scheme.name,
        signature = scheme.signature,
        module = scheme.module,
        is_pub = scheme.is_pub,
        is_foreign = scheme.is_foreign,
        decl_span = scheme.decl_span,
        deprecation = scheme.deprecation,
        id = id,
    }
    let existing_opt = self.by_name.get(scheme.name)
    if existing_opt.is_some() {
        let updated = existing_opt.unwrap()
        updated.push(with_id)
        self.by_name.set(scheme.name, updated)
    } else {
        let fresh: List(FunctionScheme) = list(1, self.allocator)
        fresh.push(with_id)
        self.by_name.set(scheme.name, fresh)
    }
    return id
}

// Resolve `name` in the caller's visibility scope. Returns the
// candidates that are reachable; if nothing is reachable but some
// hidden overloads exist, returns one of them along with its module
// for the diagnostic hint.
pub fn lookup(self: &FunctionRegistry, name: String, vis: &Visibility) FnLookup {
    let overloads_opt = self.by_name.get(name)
    if overloads_opt.is_none() { return FnLookup.FnLookMissing }
    let overloads = overloads_opt.unwrap()

    let visible: List(FunctionScheme) = list(0, self.allocator)
    let hidden_module: String? = null
    for i in 0..overloads.len {
        let f = &overloads[i]
        if visibility_for(f, vis) {
            visible.push(f.*)
        } else {
            if hidden_module.is_none() {
                f.module match {
                    Some(m) => hidden_module = Some(m),
                    None => {},
                }
            }
        }
    }
    if visible.len > 0 { return FnLookup.FnLookFound(visible) }
    if hidden_module.is_some() {
        let one: List(FunctionScheme) = list(1, self.allocator)
        one.push(overloads[0])
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
        None => return true,
        Some(m) => {
            vis.current_module match {
                Some(cur) => if cur == m { return true },
                None => {},
            }
            if !f.is_pub { return false }
            return vis.visible.contains(m)
        },
    }
}
