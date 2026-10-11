//! TEST: eq_satisfied_by_operators
//! EXIT: 0

import std.string

// `Eq` asks for `op_eq`, which is `==`: a primitive's operator function, a payload-less enum's tag
// compare, an `op_eq` reached through `op_deref`, and one derived from `op_cmp` all satisfy it.
type Color = enum {
    Red
    Green
}

type Version = struct {
    n: i32
}

fn op_cmp(a: Version, b: Version) Ord {
    return op_cmp(a.n, b.n)
}

fn same(a: $T, b: T) bool where T: Eq {
    return a == b
}

fn same_ref(a: &$T, b: &T) bool where T: Eq {
    return a.* == b.*
}

pub fn main() i32 {
    if !same(3i32, 3i32) or same(1.5f64, 2.5f64) or !same('a', 'a') or !same(true, true) {
        return 1
    }
    if !same(Color.Red, Color.Red) or same(Color.Red, Color.Green) {
        return 2
    }
    if !same(Version { n = 4 }, Version { n = 4 }) {
        return 4
    }
    const s: String = "abc"
    if !same(s, "abc") {
        return 5
    }
    const o = from_view("xy")
    defer o.deinit()
    const p = from_view("xy")
    defer p.deinit()
    if !same_ref(&o, &p) {
        return 6
    }
    return 0
}
