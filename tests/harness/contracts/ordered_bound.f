//! TEST: ordered_bound
//! EXIT: 0

import std.collections.iter
import std.collections.list
import std.option
import std.string

// `Ordered` is `op_cmp` plus the `==` it derives: primitives, `String`, a type with its own
// `op_cmp`, and an owning one compared in read mode all satisfy it.
type Version = struct {
    n: i32
}

pub fn op_cmp(a: Version, b: Version) Ord {
    return op_cmp(a.n, b.n)
}

type Handle = struct {
    owned key: i32
}

pub fn deinit(self: move Handle) {}

pub fn op_cmp(a: Handle, b: Handle) Ord {
    return op_cmp(a.key, b.key)
}

fn less(a: $T, b: T) bool where T: Ordered {
    return op_cmp(a, b) == Ord.Less
}

pub fn main() i32 {
    if !less(1i32, 2i32) or !less('a', 'b') or less(2.5f64, 1.0f64) {
        return 1
    }
    const s: String = "abc"
    if !less(s, "abd") {
        return 2
    }
    if max(Version { n = 3 }, Version { n = 5 }).n != 5 {
        return 3
    }
    let hs = [Handle { key = 2 }, Handle { key = 1 }]
    if !less(hs[1], hs[0]) {
        return 4
    }
    const xs: i32[] = [1, 3, 5, 7]
    if xs.binary_search(5).unwrap() != 2 or xs.lower_bound(4) != 2 {
        return 5
    }
    let l: List(i32) = list(3)
    defer l.deinit()
    l.push(4i32)
    l.push(9i32)
    l.push(2i32)
    if l.iter().max().unwrap() != 9 or l.iter().min_by(fn(x) { 0 - x }).unwrap() != 9 {
        return 6
    }
    return 0
}
