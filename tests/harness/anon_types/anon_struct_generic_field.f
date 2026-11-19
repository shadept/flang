//! TEST: anon_struct_generic_field
//! EXIT: 43

// An anonymous struct is a layout over the type parameters in scope: a field, payload or nested
// type naming the owner's `T` gets the instance's argument, and two instances coexist.
type Pair(T) = struct {
    inner: struct { a: T, b: T }
    tag: i32
}

type Msg(T) = enum {
    Point(struct { x: T, y: T })
    Empty
}

type Tree(K) = struct {
    type Node = struct {
        meta: struct { key: K, depth: i32 }
    }
    root: Node
}

fn sum(p: &Pair(i32)) i32 {
    return p.inner.a + p.inner.b
}

fn swap(p: Pair($T)) Pair(T) where T: copyable {
    return .{ inner = .{ a = p.inner.b, b = p.inner.a }, tag = p.tag }
}

pub fn main() i32 {
    let p: Pair(i32) = Pair(i32) { inner = .{ a = 1, b = 2 }, tag = 0 }
    const q: Pair(bool) = Pair(bool) { inner = .{ a = true, b = false }, tag = 7 }
    p.inner.a = 10
    const s: Pair(bool) = swap(q)
    const m: Msg(i32) = Msg(i32).Point(.{ x = 3, y = 4 })
    const mx: i32 = m match {
        Point(pt) => pt.x * pt.y
        Empty => 0
    }
    const t: Tree(u8) = Tree(u8) { root = .{ meta = .{ key = 9, depth = 2 } } }
    const sb: i32 = if s.inner.a { 0 } else { 1 }
    return sum(&p) + s.tag + mx + (t.root.meta.key as i32) + t.root.meta.depth + sb
}
