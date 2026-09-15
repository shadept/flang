//! TEST: op_deref_operator_arith_cmp
//! EXIT: 12

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

// Arithmetic and `op_cmp`-derived comparisons reach the inner type the same way.
pub fn main() i32 {
    const b = Box { inner = Point { x = 1, y = 2 } }
    const c = Box { inner = Point { x = 3, y = 4 } }
    const s = b + c
    let n = s.x + s.y - 7
    if b < c { n = n + 1 }
    if c >= b { n = n + 8 }
    if c < b { n = n + 16 }
    return n
}
