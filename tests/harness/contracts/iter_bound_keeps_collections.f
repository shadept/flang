//! TEST: iter_bound_keeps_collections
//! EXIT: 0

import std.collections.dict
import std.collections.iter
import std.collections.list
import std.option

// `std.iter`'s catch-alls take any `it: $I` as written; `I: Iterator($T)` keeps them off a `List`
// or a `Dict` receiver, which reach their own `last` and `any`.
pub fn main() i32 {
    let xs: List(i32) = list(3)
    defer xs.deinit()
    xs.push(1i32)
    xs.push(2i32)
    xs.push(3i32)
    if xs.last().unwrap() != 3 {
        return 1
    }
    let d: Dict(i32, i32) = dict()
    defer d.deinit()
    d[1i32] = 10i32
    if !d.any({ k, v => k == 1 and v == 10 }) {
        return 2
    }
    // And on an iterator they still apply.
    if xs.iter().map({ x => x * 2 }).last().unwrap() != 6 {
        return 3
    }
    if xs.iter().filter({ x => x > 1 }).count() != 2 {
        return 4
    }
    return 0
}
