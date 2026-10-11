//! TEST: contract_combined
//! EXIT: 7

type Point = struct {
    x: i32
    y: i32
}

fn op_eq(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y
}

fn weight(p: Point) i32 {
    return p.x + p.y
}

type Eq = contract {
    fn op_eq(a: Self, b: Self) bool
}

type Weighed = contract {
    fn weight(self: Self) i32
}

// A named `+` combination, and `copyable` among its parts.
type Key = copyable + Eq + Weighed

fn heavier_if_same(a: $T, b: T) i32 where T: Key {
    if a == b {
        return a.weight()
    }
    return 0
}

pub fn main() i32 {
    const p = Point { x = 3, y = 4 }
    return heavier_if_same(p, p)
}
