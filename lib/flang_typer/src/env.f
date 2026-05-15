// TypeEnv — scoped `name → Binding` map for the checker.
//
// Scopes stack: `push_scope` opens a fresh inner scope, `pop_scope`
// drops it. `lookup` searches from innermost to outermost. The
// outermost scope is the module-level binding set populated by
// `collect_signatures` and the nominal registry.
//
// `Binding` carries the scheme, the declaration's `NodeId` (so the
// LSP can resolve `IdentifierExpr → declaration site`), and a const
// flag for assignment-target checking.

import std.allocator
import std.dict
import std.list
import std.option
import std.stack
import std.string
import flang_typer.scheme
import flang_typer.node_id

pub type Binding = struct {
    scheme: Scheme
    decl: NodeId
    is_const: bool
}

pub type Scope = struct {
    bindings: Dict(String, Binding)
}

pub type TypeEnv = struct {
    scopes: Stack(Scope)
    allocator: &Allocator
}

pub fn type_env(allocator: &Allocator? = null) TypeEnv {
    let alloc = allocator.or_global()
    let scopes: Stack(Scope) = stack(0, alloc)
    let bindings: Dict(String, Binding) = dict(alloc)
    let initial: Scope = .{ bindings = bindings }
    scopes.push(initial)
    return .{ scopes = scopes, allocator = alloc }
}

pub fn deinit(self: &TypeEnv) {
    loop {
        self.scopes.pop() match {
            Some(scope) => { let s = scope; s.bindings.deinit() },
            None => break,
        }
    }
    self.scopes.deinit()
}

pub fn push_scope(self: &TypeEnv) {
    let bindings: Dict(String, Binding) = dict(self.allocator)
    let fresh: Scope = .{ bindings = bindings }
    self.scopes.push(fresh)
}

pub fn pop_scope(self: &TypeEnv) {
    if self.scopes.len() <= 1 { panic("pop_scope: cannot pop global scope") }
    let s = self.scopes.pop().expect("pop_scope: no scope")
    let scope = s; scope.bindings.deinit()
}

pub fn bind(self: &TypeEnv, name: String, binding: Binding) {
    self.scopes.peek_ref() match {
        Some(top) => top.bindings.set(name, binding),
        None => panic("bind: no open scope"),
    }
}

pub fn lookup(self: &TypeEnv, name: String) Binding? {
    let frames = self.scopes.as_slice()
    let i: isize = (frames.len as isize) - 1
    loop {
        if i < 0 { break }
        let scope = &frames[i as usize]
        let hit = scope.bindings.get(name)
        if hit.is_some() { return hit }
        i = i - 1
    }
    return null
}

// True iff `name` is bound in the *current* (innermost) scope. Used
// to detect same-scope shadowing.
pub fn exists_in_current(self: &TypeEnv, name: String) bool {
    self.scopes.peek_ref() match {
        Some(top) => return top.bindings.contains(name),
        None => return false,
    }
    return false
}
