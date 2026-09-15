//! TEST: op_deref_operator_eq
//! EXIT: 15

type Point = struct {
    x: i32
    y: i32
}

fn op_eq(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y
}

fn op_add(a: Point, b: Point) Point {
    return .{ x = a.x + b.x, y = a.y + b.y }
}

fn op_cmp(a: Point, b: Point) Ord {
    if a.x < b.x {
        return Ord.Less
    }
    if a.x > b.x {
        return Ord.Greater
    }
    return Ord.Equal
}

type Box = struct {
    inner: Point
}

fn op_deref(self: &Box) &Point {
    return &self.inner
}

// An operator operand peels through `op_deref` like a receiver: either side, or both.
pub fn main() i32 {
    const p = Point { x = 1, y = 2 }
    const b = Box { inner = Point { x = 1, y = 2 } }
    const c = Box { inner = Point { x = 3, y = 4 } }
    let n = 0
    if b == p { n = n + 1 }
    if p == b { n = n + 2 }
    if b == b { n = n + 4 }
    if b != c { n = n + 8 }
    if b == c { n = n + 16 }
    return n
}
