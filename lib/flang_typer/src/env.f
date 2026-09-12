// TypeEnv - scoped `name → Binding` map for the checker.
//
// Scopes stack: `push_scope` opens a fresh inner scope, `pop_scope` drops it. `lookup` searches
// from innermost to outermost. The outermost scope is the module-level binding set populated by
// `collect_signatures` and the nominal registry.
//
// `Binding` carries the scheme, the declaration's `NodeId` (so the
// LSP can resolve `IdentifierExpr → declaration site`), and a const
// flag for assignment-target checking.

import std.allocator
import std.collections.dict
import std.collections.stack
import std.option

import flang_typer.node_id
import flang_typer.scheme

pub type Binding = struct {
    scheme: Scheme
    decl: NodeId
    is_const: bool
    // True for `$T` signature/nominal type parameters. Type resolution lets these shadow nominals;
    // value lookups ignore the flag.
    is_type_param: bool
}

// One lexical scope's bindings. Allocates through the owning `TypeEnv`'s allocator.
pub type Scope = struct {
    bindings: UnmanagedDict(String, Binding)
}

pub fn deinit(self: &Scope, allocator: &Allocator) {
    self.bindings.deinit(allocator)
}

// The lexical environment of the function being checked: a stack of scopes, innermost on top, each
// mapping a name to its binding. Lookup walks from the innermost scope outward. One allocator
// serves every scope's table.
pub type TypeEnv = struct {
    scopes: UnmanagedStack(Scope)
    // The one allocator every scope allocates through.
    allocator: &Allocator
}

pub fn type_env(allocator: &Allocator? = null) TypeEnv {
    let out: TypeEnv
    out.allocator = allocator.or_global()
    let initial: Scope
    out.scopes.push(move initial, out.allocator)
    return move out
}

pub fn deinit(self: &TypeEnv) {
    loop {
        self.scopes.pop() match {
            Some(scope) => {
                let s = move scope
                s.bindings.deinit(self.allocator)
            }
            None => break
        }
    }
    self.scopes.deinit(self.allocator)
}

// Element form (README, Expected functions). The value carries its own allocator.
pub fn deinit(self: &TypeEnv, allocator: &Allocator) {
    self.deinit()
}

pub fn push_scope(self: &TypeEnv) {
    let fresh: Scope
    self.scopes.push(move fresh, self.allocator)
}

pub fn pop_scope(self: &TypeEnv) {
    if self.scopes.len() <= 1 {
        panic("pop_scope: cannot pop global scope")
    }
    let s = expect(self.scopes.pop(), "pop_scope: no scope")
    let scope = move s
    scope.bindings.deinit(self.allocator)
}

pub fn bind(self: &TypeEnv, name: String, binding: Binding) {
    self.scopes.peek_ref() match {
        Some(top) => top.bindings.set(name, binding, self.allocator)
        None => panic("bind: no open scope")
    }
}

pub fn lookup(self: &TypeEnv, name: String) Binding? {
    let frames = self.scopes.as_slice()
    let i: isize = (frames.len as isize) - 1
    loop {
        if i < 0 {
            break
        }
        let scope = &frames[i as usize]
        let hit = scope.bindings.get(name)
        if hit.is_some() {
            return hit
        }
        i = i - 1
    }
    return null
}

// Number of open scopes. Lambda capture analysis compares a binding's depth against the scope count
// at the lambda's boundary.
pub fn depth(self: &TypeEnv) usize {
    return self.scopes.len()
}

// The scope index `name` is bound at (0 = outermost), or null. Same walk as `lookup`; capture
// analysis needs the depth, not the binding.
pub fn lookup_depth(self: &TypeEnv, name: String) usize? {
    let frames = self.scopes.as_slice()
    let i = frames.len
    while i > 0 {
        i = i - 1
        if frames[i].bindings.contains(name) {
            return Some(i)
        }
    }
    return null
}

// True iff `name` is bound in the *current* (innermost) scope. Used to detect same-scope shadowing.
pub fn exists_in_current(self: &TypeEnv, name: String) bool {
    self.scopes.peek_ref() match {
        Some(top) => return top.bindings.contains(name)
        None => return false
    }
    return false
}
