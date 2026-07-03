//! TEST: op_try_niche_pointer_target
//! EXIT: 0

// `?` whose enclosing function returns `Option(&T)` (niche-pointer layout)
// must not crash codegen. Previously, lowering an unspecialized `None`
// constructor for a niche-typed Option failed with E3002 because
// `LowerIdentifier` only handled the tagged-enum representation.

import std.option

type Page = struct { size: usize }

fn might_fail() u8[]? {
    let xs: u8[] = [1, 2, 3]
    return Some(xs)
}

fn caller() &Page? {
    let bytes = might_fail()?
    if bytes.len == 0 { return null }
    return null
}

pub fn main() i32 {
    let p = caller()
    if p.is_some() { return 1 }
    return 0
}
