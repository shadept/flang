// Type-alias registry — `type X = <TypeExpr>` bodies indexed by FQN.
//
// Aliases are not nominal types: they carry no fields or variants and never
// appear in a `Ty`. They expand transparently to their right-hand side at
// the point of use, so the registry stores the unresolved body and lets
// `checker.resolve_named` expand it lazily. Lazy expansion makes alias
// chains and cross-module alias targets resolve regardless of declaration
// or module order.
//
// Lookup mirrors `NominalRegistry.lookup`'s visibility rules exactly: a
// dotted name is self-authorising, a bare name resolves against the current
// module then scans visible modules. Only non-generic aliases are modelled
// today; a generic alias (`type Result(T, E) = ...`) is a follow-up.

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.string_builder
import flang_parser.ast
import flang_typer.visibility
import flang_typer.nominal_registry

pub type AliasRegistry = struct {
    // FQN -> alias body. Keys are views into `owned_fqns`; values borrow the
    // parser AST (which outlives the checker), so neither is freed on deinit.
    bodies: Dict(String, TypeExpr)
    owned_fqns: List(OwnedString)
    allocator: &Allocator
}

pub fn alias_registry(allocator: &Allocator? = null) AliasRegistry {
    let alloc = allocator.or_global()
    return .{
        bodies = dict(alloc),
        owned_fqns = list(0, alloc),
        allocator = alloc,
    }
}

pub fn deinit(self: &AliasRegistry) {
    for i in 0..self.owned_fqns.len {
        let s = &self.owned_fqns[i]
        s.deinit()
    }
    self.owned_fqns.deinit()
    self.bodies.deinit()
}

// True when an alias is already registered under this exact FQN.
pub fn contains(self: &AliasRegistry, fqn: String) bool {
    return self.bodies.contains(fqn)
}

// Register an alias. The caller transfers ownership of `fqn_owned`; its heap
// buffer keeps the `bodies` key view stable for the registry's lifetime.
// `body` borrows the parser AST and is never freed here.
pub fn register(self: &AliasRegistry, fqn_owned: OwnedString, body: TypeExpr) {
    let idx = self.owned_fqns.len
    self.owned_fqns.push(fqn_owned)
    let stable: String = self.owned_fqns[idx].as_view()
    self.bodies.set(stable, body)
}

// Resolve an alias name in the caller's visibility scope, returning its body
// for lazy expansion. Name shapes match `NominalRegistry.lookup`: a full FQN
// bypasses visibility, a current-module-prefixed name resolves directly, and
// a bare short name is scanned across visible modules.
pub fn lookup(self: &AliasRegistry, name: String, vis: &Visibility) TypeExpr? {
    let direct = self.bodies.get(name)
    if direct.is_some() { return direct }

    if vis.current_module.is_some() {
        let cur = vis.current_module.unwrap()
        let qualified = $"{cur}.{name}"
        let q = self.bodies.get(qualified.as_view())
        qualified.deinit()
        if q.is_some() { return q }
    }

    for entry in self.bodies {
        let fqn = entry.key
        let dot = last_dot(fqn)
        let short = short_name_of(fqn, dot)
        if short != name { continue }
        let module = module_of(fqn, dot)
        if vis.allows(module) { return Some(entry.value) }
    }
    return null
}
