//! TEST: type_params_on_name
//! EXIT: 15

import std.collections.list

// A type declaration's parameters sit on its name (RFC-047): structs, enums and contracts take them
// as their own, and any other body is a generic alias that expands at each use.

type Box = struct(T) {
    type Keyed(K) = (K, T)
    v: T
}
type Pair(T) = struct {
    a: T
    b: T
}
type Tagged(T) = enum {
    On(T)
    Off
}
type Shows(T) = contract {
    fn shown(self: &Self) T
}
type Grid(T) = List(List(T))
type Shelf(T) = Box(T)
type Swapped(A, B) = (B, A)

fn shown(self: &Pair(i32)) i32 {
    return self.a
}

fn show(x: &$S) T where S: Shows($T) {
    return x.shown()
}

fn first(p: Pair(i32)) i32 {
    return p.a + p.b
}

pub fn main() i32 {
    const p: Pair(i32) = Pair(i32) { a = 1, b = 2 }
    const s: Shelf(i32) = Shelf(i32) { v = 3 }
    const t: Tagged(i32) = Tagged(i32).On(4)
    const n: usize = size_of(Shelf(i16))
    const keyed: Box(i32).Keyed(u8) = (6, 7)
    const kn: usize = size_of(Box(i16).Keyed(u8))
    const w: Swapped(u8, i32) = (5, 0)
    let g: Grid(i32) = list(0)
    defer g.deinit()
    const k: i32 = t match {
        On(x) => x
        Off => 0
    }
    // 3 + 3 + 4 + 2 + 5 + 0 - 1 + 7 - 4 - 4
    const nested: i32 = keyed.1 - kn as i32 - 4
    return first(p) + s.v + k + n as i32 + w.0 + g.len as i32 - show(&p) + nested
}
