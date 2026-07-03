//! TEST: generic_multi_return_type
//! EXIT: 0

// Test that generic functions with identical parameter types but different
// return types produce separate specializations (monomorphization fix).

type Point = struct {
    x: i32,
    y: i32
}

type Color = struct {
    r: u8,
    g: u8,
    b: u8
}

fn make_default() $T {
    let result: T
    return result
}

fn identity(val: i32) $T {
    let result: T
    return result
}

pub fn main() i32 {
    // Two specializations of make_default with no params but different return types
    let p: Point = make_default()
    let c: Color = make_default()

    // Verify they are independently zero-initialized
    if (p.x != 0) { return 1 }
    if (p.y != 0) { return 2 }
    if (c.r != 0) { return 3 }
    if (c.g != 0) { return 4 }

    // Two specializations of identity(i32) with different return types
    let p2: Point = identity(42)
    let c2: Color = identity(42)

    return 0
}
