// Visibility — one value passed through every name lookup.
//
// Replaces the C# checker's pattern of threading a `HashSet<string>?`
// alongside an optional current-module path through every registry
// call. Here both are bundled into a single struct so the contract is
// uniform across nominal and function registries.
//
// Semantics:
//   - `current_module` is the module the checker is currently inside
//     (None when checking out-of-project synthetic code such as
//     generated lambda hosts).
//   - `visible` is the set of FQN-prefix module names whose `pub`
//     declarations are accessible from `current_module`. The set is
//     transitive over `pub import` re-exports and includes
//     `current_module` itself.
//
// Lookups consult `visible` only for short-name resolution. FQN-style
// references (containing a dot) bypass visibility entirely — an
// explicit dotted name is unambiguous and self-authorising.

import std.allocator
import std.option
import std.set
import std.string

pub type Visibility = struct {
    current_module: String?
    visible: Set(String)
}

// Construct a visibility scope. `current_module` is None for
// synthesized contexts; `visible` is built by the caller from the
// import graph.
pub fn visibility(current_module: String?, visible: Set(String)) Visibility {
    return .{ current_module = current_module, visible = visible }
}

// Empty visibility — used by tests and by codegen-time lookups that
// don't need filtering (the source code has already been validated).
pub fn open(allocator: &Allocator? = null) Visibility {
    let alloc = allocator.or_global()
    let s: Set(String) = set(alloc)
    return .{ current_module = null, visible = s }
}

// True when `module` is reachable from `current_module`. Same-module
// references are always allowed; otherwise membership in `visible`
// decides.
pub fn allows(self: &Visibility, module: String) bool {
    self.current_module match {
        Some(cur) => if cur == module { return true },
        None => {},
    }
    return self.visible.contains(module)
}
