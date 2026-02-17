//! TEST: struct_field_shorthand
//! EXIT: 52

type Point = struct {
    x: i32,
    y: i32
}

fn make_point(p: Point) i32 {
    return p.x + p.y
}

pub fn main() i32 {
    const x: i32 = 42
    const y: i32 = 10

    // All shorthand
    let p1: Point = Point { x, y }

    // Mixed: shorthand first, explicit second
    let p2: Point = Point { x, y = 5 }

    // Mixed: explicit first, shorthand last (no trailing comma)
    let p3: Point = Point { x = 1, y }

    // Anonymous struct shorthand
    let a = .{ x, y }

    // Verify values: p1.x(42) + p1.y(10) = 52
    // Also sanity check the others via side effects
    if (p2.y != 5) {
        return 1
    }
    if (p3.x != 1) {
        return 2
    }
    if (a.x != 42) {
        return 3
    }

    return p1.x + p1.y
}
