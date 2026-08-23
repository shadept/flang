//! TEST: for_by_ref
//! EXIT: 36

// `for &x in xs` iterates through `iter_ref`: `x` is `&T` into the
// collection's storage, so writes land in place. Works on List and
// slices; a custom type joins by defining `iter_ref`.

import std.list

type Counter = struct { n: i32 }
type CounterRef = struct { c: &Counter, done: bool }
fn iter_ref(c: &Counter) CounterRef { return .{ c = c, done = false } }
fn next(it: &CounterRef) &i32? {
    if it.done { return null }
    it.done = true
    return Some(&it.c.n)
}

pub fn main() i32 {
    let xs: List(i32) = list(0)
    defer xs.deinit()
    xs.push(1i32); xs.push(2i32); xs.push(3i32)
    for &x in xs { x.* = x.* * 10 }          // 10, 20, 30
    const s = xs.as_slice()
    for &x in s { x.* = x.* + 1 }            // 11, 21, 31
    let sum = 0i32
    for x in xs { sum = sum + x }            // 63
    let c = Counter { n = 5 }
    for &n in c { n.* = n.* - 32 }           // -27
    return sum + c.n
}
