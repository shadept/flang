//! TEST: nested_type_basic
//! EXIT: 42

// RFC-046: a struct or enum body declares types beside its fields and variants. Inside the body
// they are named bare and see the owner's parameters; outside, through the owner:
// `Tree(bool).Node`.
type Tree = struct(T) {
    type Node = struct {
        value: T
        weight: Weight
    }
    type Weight = i32
    root: Node
}

fn weight_of(n: &Tree($T).Node) i32 {
    return n.weight
}

type Shape = enum {
    type Size = struct { w: i32, h: i32 }
    Rect(Size)
    Dot
}

pub fn main() i32 {
    const t: Tree(bool) = Tree(bool) { root = .{ value = true, weight = 30 } }
    const n: Tree(bool).Node = t.root
    const s: Shape = Shape.Rect(.{ w = 3, h = 4 })
    const area: i32 = s match {
        Rect(sz) => sz.w * sz.h
        Dot => 0
    }
    const w: Tree(u8).Weight = 0
    return weight_of(&n) + area + w
}
