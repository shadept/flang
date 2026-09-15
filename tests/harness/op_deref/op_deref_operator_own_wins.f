//! TEST: op_deref_operator_own_wins
//! EXIT: 7

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

fn op_eq(a: Box, b: Box) bool {
    return false
}

// An operator declared on the wrapper itself wins over the one reached through the hop.
pub fn main() i32 {
    const b = Box { inner = Point { x = 1, y = 2 } }
    if b == b {
        return 1
    }
    return 7
}
