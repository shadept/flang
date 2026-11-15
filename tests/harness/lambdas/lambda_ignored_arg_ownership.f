//! TEST: lambda_ignored_arg_ownership
//! COMPILE-WARNING: W2006 `it` is never released
//! COMPILE-WARNING: W2006 `_` is never released: it is still live at the end of its scope - move it on every path, or name it to release it
//! EXIT: 0

// `{ 0 }`, `{ it => 0 }` and `{ _ => 0 }` are the same lambda: each owns the string it is handed
// and leaves it unreleased, so each is W2006. `_` only drops the name.

import std.string

fn call_with(s: move OwnedString, f: $F) i32 where F: fn(move OwnedString) i32 {
    return f(s)
}

pub fn main() i32 {
    const a: i32 = call_with(from_view("a")) { 0 } // warning[W2006]: `it` is never released
    const b: i32 = call_with(from_view("b")) { it => 0 } // warning[W2006]: `it` is never released
    const c: i32 = call_with(from_view("c")) { _ => 0 } // warning[W2006]: `_` is never released
    return a + b + c
}
