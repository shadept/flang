// A registry of values named by fully qualified name, looked up with import visibility: the shared
// shape behind the alias and constant registries (type-alias bodies, module-level constant types),
// and any future "named thing per module" table.
//
// Lookup mirrors `NominalRegistry.lookup`'s visibility rules: a dotted name is self-authorising, a
// bare name resolves against the current module then scans visible modules.
//
// Names are interned in a `StringPool` and the table keys by `StrId`, so a name is stored once and
// lookups hash and compare integers. A name is never forgotten: evicting a module drops its values
// and a re-registration under the same name lands on the same id, which is what lets a snapshot
// taken before an eviction be compared after the re-registration by id.

import std.allocator
import std.collections.dict
import std.collections.list
import std.collections.string_pool
import std.option
import std.string
import std.string_builder

import flang_typer.nominal_registry
import flang_typer.visibility

// A registry of `V`s named by FQN. One allocator serves the table and the name pool.
pub type FqnMap = struct(V) {
    // Name id -> value. Values are stored as-is and never freed here: they borrow the AST or the
    // engine's allocator.
    entries: UnmanagedDict(StrId, V)
    names: StringPool
    allocator: &Allocator
}

// Creates an empty map. Nothing allocates until the first `register`.
pub fn fqn_map() FqnMap($V) {
    let entries: UnmanagedDict(StrId, V)
    return .{ entries = move entries, names = string_pool(), allocator = context.allocator }
}

// Frees the table and the name pool. The values are not deinited: the map never owned them.
pub fn deinit(self: move FqnMap($V)) {
    self.entries.deinit(self.allocator)
    self.names.deinit()
}

// Returns whether a value is registered under exactly `fqn`.
pub fn contains(self: &FqnMap($V), fqn: String) bool {
    return self.names.find(fqn) match {
        Some(id) => self.entries.contains(id)
        None => false
    }
}

// Registers `value` under `fqn`, replacing a value already there. Takes ownership of `fqn`: the
// name is copied into the pool and `fqn` is freed, whether or not it was already interned. Panics
// when the pool or the table cannot grow.
pub fn register(self: &FqnMap($V), fqn: move OwnedString, value: move V) {
    const id = self.names.intern(fqn.view)
    fqn.deinit()
    self.entries.set(id, value, self.allocator)
}

// Returns the name with id `id`, as a view valid until the next `register`. Panics on an id the map
// never handed out.
pub fn name(self: &FqnMap($V), id: StrId) String {
    return self.names.get(id)
}

// Drops every value whose FQN sits directly in `module`. The names stay interned, so a value
// registered again under one of them lands on the same id.
pub fn evict_module(self: &FqnMap($V), module: String) {
    let doomed: List(StrId) = list(0)
    defer doomed.deinit()
    for entry in self.entries {
        const fqn = self.names.get(entry.key)
        const dot = last_dot(fqn)
        if module_of(fqn, dot) == module {
            doomed.push(entry.key)
        }
    }
    for id in doomed {
        const _gone = self.entries.remove(id)
    }
}

// Returns the value registered under exactly `fqn`, or null.
pub fn get_fqn(self: &FqnMap($V), fqn: String) V? where V: copyable {
    return self.names.find(fqn) match {
        Some(id) => self.entries.get(id)
        None => null
    }
}

// A visibility-scoped hit: the winning FQN, as a view into the name pool valid until the next
// `register`, and its value.
pub type FqnHit = struct(V) {
    fqn: String
    value: V
}

// Resolves `name` in `vis`'s scope and returns the winning FQN alongside the value, for a caller
// that must cite which name won. A dotted or exact name matches itself; a bare name matches the
// current module's, then the first visible module's, in table order.
pub fn lookup_entry(self: &FqnMap($V), name: String, vis: &Visibility) FqnHit($V)?
where V: copyable {
    return self.lookup_id(name, vis) match {
        Some(id) => Some(.{ fqn = self.names.get(id), value = self.entries.get(id).unwrap() })
        None => null
    }
}

// The name id `name` resolves to in `vis`'s scope, or null. What both lookups are built on: an
// exact or dotted name matches itself, a bare name the current module's, then the first visible
// module's, in table order.
pub fn lookup_id(self: &FqnMap($V), name: String, vis: &Visibility) StrId? {
    const exact = self.names.find(name)
    if exact.is_some() and self.entries.get_ref(exact.unwrap()).is_some() {
        return exact
    }

    if vis.current_module.is_some() {
        let cur = vis.current_module.unwrap()
        let qualified = $"{cur}.{name}"
        defer qualified.deinit()
        const own = self.names.find(qualified.view)
        if own.is_some() and self.entries.get_ref(own.unwrap()).is_some() {
            return own
        }
    }

    for entry in self.entries {
        const fqn = self.names.get(entry.key)
        const dot = last_dot(fqn)
        if short_name_of(fqn, dot) != name {
            continue
        }
        if vis.allows(module_of(fqn, dot)) {
            return Some(entry.key)
        }
    }
    return null
}

// Resolves `name` in `vis`'s scope and returns the value, or null.
pub fn lookup(self: &FqnMap($V), name: String, vis: &Visibility) V? where V: copyable {
    return self.lookup_entry(name, vis) match {
        Some(h) => Some(h.value)
        None => null
    }
}

// `lookup`, lending the value: the map keeps it, and an owning `V` is read where it lies.
pub fn lookup_ref(self: &FqnMap($V), name: String, vis: &Visibility) &V? {
    return self.lookup_id(name, vis) match {
        Some(id) => self.entries.get_ref(id)
        None => null
    }
}
