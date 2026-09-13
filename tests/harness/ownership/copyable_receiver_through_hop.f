//! TEST: copyable_receiver_through_hop
//! EXIT: 5

type Point = struct {
    x: i32
    y: i32
}

fn sum(p: Point) i32 {
    return p.x + p.y
}

type Box = struct {
    inner: Point
}

fn op_deref(self: &Box) &Point {
    return &self.inner
}

// A copyable value read through the hop is a copy, and a copy is never a consuming site.
pub fn main() i32 {
    let b = Box { inner = .{ x = 2, y = 3 } }
    return b.sum()
}
