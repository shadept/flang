//! TEST: nested_type_generic
//! EXIT: 24

// RFC-046: a nested type may be generic itself, nest further, sit in a block-scoped type of a
// generic function, or in an anonymous struct. Its name is its path from the owner.
import std.io.print

type Outer = struct(A) {
    type Pair = struct(B) {
        a: A
        b: B
        type Deep = enum { Yes(A), No }
    }
    p: Pair(i32)
}

fn wrap(x: $T) i32 where T: copyable {
    type Local = struct {
        type Inner = struct { v: T, n: i32 }
        i: Inner
    }
    const l: Local = Local { i = .{ v = x, n = 5 } }
    return l.i.n
}

pub fn main() i32 {
    const o: Outer(u8) = Outer(u8) { p = .{ a = 1, b = 2 } }
    const pr: Outer(u8).Pair(bool) = .{ a = 3, b = true }
    const d: Outer(u8).Pair(bool).Deep = Outer(u8).Pair(bool).Deep.Yes(4)
    const anon: struct { type K = i32, k: K } = .{ k = 7 }
    const name: String = type_of(pr).name
    println(name)
    return o.p.b + wrap(1.5f64) + anon.k + (name.len as i32)
}
