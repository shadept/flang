//! TEST: stdlib_dict_iter_chain
//! EXIT: 0

// Cross-module combinator chains: Dict's keys()/values() iterators driven
// through std.iter's adapters and consumers, with capturing closures and
// unannotated lambda parameters throughout. Lives here because dict.f
// cannot import std.iter (module cycle through std.list).

import std.dict
import std.iter
import std.list
import std.option

pub fn main() i32 {
    let d: Dict(u32, i32) = dict()
    defer d.deinit()
    d.set(1u32, 10i32)
    d.set(2u32, 20i32)
    d.set(3u32, 30i32)

    // keys through filter + to_list, with a captured threshold
    let min_key = 1u32
    let big = d.keys().filter(fn(k) { k > min_key }).to_list()
    defer big.deinit()
    if big.len != 2 { return 1 }

    // values through map + fold
    let scale = 2i32
    let total = d.values().map(fn(v) { v * scale }).fold(0i32, fn(a, v) { a + v })
    if total != 120 { return 2 }

    // consumers directly over dict iterators
    if d.keys().count() != 3 { return 3 }
    if d.values().max().unwrap() != 30 { return 4 }
    if d.values().min_by(fn(v) { 0 - v }).unwrap() != 30 { return 5 }
    if !d.values().any(fn(v) { v == 20 }) { return 6 }

    return 0
}
