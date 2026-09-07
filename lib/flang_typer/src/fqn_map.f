// FQN-keyed map with import-visibility lookup - the shared shape behind the alias and constant
// registries (type-alias bodies, module-level constant types), and any future "named thing per
// module" table.
//
// Lookup mirrors `NominalRegistry.lookup`'s visibility rules: a dotted name is self-authorising, a
// bare name resolves against the current module then scans visible modules.

import std.allocator
import std.collections.dict
import std.collections.list
import std.option
import std.string
import std.string_builder

import flang_typer.nominal_registry
import flang_typer.visibility

// A registry of values named by fully qualified name, looked up with import visibility: a dotted
// name resolves as itself, a bare name resolves against the current module and then the modules it
// can see. One allocator serves the table and the key buffers it owns.
pub type FqnMap = struct(V) {
    // FQN -> value. Keys are views into `owned_fqns`; values are stored as-is and never freed here
    // (they borrow the AST or the engine's allocator).
    entries: UnmanagedDict(String, V)
    owned_fqns: UnmanagedList(OwnedString)
    // The one allocator both containers allocate through.
    allocator: &Allocator
}

// Creates an empty map. Nothing allocates until the first `register`.
//
// - `allocator`: kept for the map's whole life. Null is the global allocator.
pub fn fqn_map(allocator: &Allocator? = null) FqnMap($V) {
    let out: FqnMap(V)
    out.allocator = allocator.or_global()
    return out
}

pub fn deinit(self: &FqnMap($V)) {
    self.owned_fqns.deinit(self.allocator)
    self.entries.deinit(self.allocator)
}

// True when a value is already registered under this exact FQN.
pub fn contains(self: &FqnMap($V), fqn: String) bool {
    return self.entries.contains(fqn)
}

// Register a value. The caller transfers ownership of `fqn_owned`; its heap buffer keeps the key
// view stable for the map's lifetime.
pub fn register(self: &FqnMap($V), fqn_owned: OwnedString, value: V) {
    let idx = self.owned_fqns.len
    self.owned_fqns.push(fqn_owned, self.allocator)
    let stable = self.owned_fqns[idx].as_view()
    self.entries.set(stable, value, self.allocator)
}

// Drop every entry whose FQN sits directly in `module`. The key buffers stay in `owned_fqns`:
// nothing else views them, and a re-registration brings its own.
pub fn evict_module(self: &FqnMap($V), module: String) {
    let doomed: List(String) = list(0, self.allocator)
    defer doomed.deinit()
    for entry in self.entries {
        const dot = last_dot(entry.key)
        if module_of(entry.key, dot) == module {
            doomed.push(entry.key)
        }
    }
    for k in doomed {
        const _gone = self.entries.remove(k)
    }
}

// Direct FQN read, no visibility scope.
pub fn get_fqn(self: &FqnMap($V), fqn: String) V? {
    return self.entries.get(fqn)
}

// A visibility-scoped hit that also names the winning FQN. `fqn` is the map's stable key view
// (owned_fqns-backed), valid for the map's lifetime.
pub type FqnHit = struct(V) {
    fqn: String
    value: V
}

// Like `lookup`, but returns the stable FQN key alongside the value - for consumers that need to
// cite WHICH constant won (RtConst). One linear scan per case; these maps are small.
pub fn lookup_entry(self: &FqnMap($V), name: String, vis: &Visibility) FqnHit($V)? {
    // Dotted (or exact) name: match the stored key itself, so the returned view is the stable one,
    // not the caller's transient buffer.
    for entry in self.entries {
        if entry.key == name {
            return Some(.{ fqn = entry.key, value = entry.value })
        }
    }

    if vis.current_module.is_some() {
        let cur = vis.current_module.unwrap()
        let qualified = $"{cur}.{name}"
        for entry in self.entries {
            if entry.key == qualified.as_view() {
                qualified.deinit()
                return Some(.{ fqn = entry.key, value = entry.value })
            }
        }
        qualified.deinit()
    }

    for entry in self.entries {
        let fqn = entry.key
        let dot = last_dot(fqn)
        let short = short_name_of(fqn, dot)
        if short != name {
            continue
        }
        let module = module_of(fqn, dot)
        if vis.allows(module) {
            return Some(.{ fqn = entry.key, value = entry.value })
        }
    }
    return null
}

// Resolve a name in the caller's visibility scope.
pub fn lookup(self: &FqnMap($V), name: String, vis: &Visibility) V? {
    return self.lookup_entry(name, vis) match {
        Some(h) => Some(h.value)
        None => null
    }
}
