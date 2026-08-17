// FQN-keyed map with import-visibility lookup - the shared shape behind
// the alias and constant registries (type-alias bodies, module-level
// constant types), and any future "named thing per module" table.
//
// Lookup mirrors `NominalRegistry.lookup`'s visibility rules: a dotted
// name is self-authorising, a bare name resolves against the current
// module then scans visible modules.

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.string_builder
import flang_typer.visibility
import flang_typer.nominal_registry

pub type FqnMap = struct(V) {
    // FQN -> value. Keys are views into `owned_fqns`; values are stored
    // as-is and never freed here (they borrow the AST or the engine's
    // allocator).
    entries: Dict(String, V)
    owned_fqns: List(OwnedString)
    allocator: &Allocator
}

pub fn fqn_map(allocator: &Allocator? = null) FqnMap($V) {
    let alloc = allocator.or_global()
    return .{
        entries = dict(alloc),
        owned_fqns = list(0, alloc),
        allocator = alloc,
    }
}

pub fn deinit(self: &FqnMap($V)) {
    for i in 0..self.owned_fqns.len {
        let s = &self.owned_fqns[i]
        s.deinit()
    }
    self.owned_fqns.deinit()
    self.entries.deinit()
}

// True when a value is already registered under this exact FQN.
pub fn contains(self: &FqnMap($V), fqn: String) bool {
    return self.entries.contains(fqn)
}

// Register a value. The caller transfers ownership of `fqn_owned`; its heap
// buffer keeps the key view stable for the map's lifetime.
pub fn register(self: &FqnMap($V), fqn_owned: OwnedString, value: V) {
    let idx = self.owned_fqns.len
    self.owned_fqns.push(fqn_owned)
    let stable = self.owned_fqns[idx].as_view()
    self.entries.set(stable, value)
}

// Direct FQN read, no visibility scope.
pub fn get_fqn(self: &FqnMap($V), fqn: String) V? {
    return self.entries.get(fqn)
}

// Resolve a name in the caller's visibility scope.
pub fn lookup(self: &FqnMap($V), name: String, vis: &Visibility) V? {
    let direct = self.entries.get(name)
    if direct.is_some() { return direct }

    if vis.current_module.is_some() {
        let cur = vis.current_module.unwrap()
        let qualified = $"{cur}.{name}"
        let q = self.entries.get(qualified.as_view())
        qualified.deinit()
        if q.is_some() { return q }
    }

    for entry in self.entries {
        let fqn = entry.key
        let dot = last_dot(fqn)
        let short = short_name_of(fqn, dot)
        if short != name { continue }
        let module = module_of(fqn, dot)
        if vis.allows(module) { return Some(entry.value) }
    }
    return null
}
