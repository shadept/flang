//! TEST: error_e2011_type_mismatch
//! COMPILE-ERROR: E2011

// Test that E2011 highlights the specific mismatched argument
// when a function exists but argument types don't match

struct Point {
    x: i32,
    y: i32
}

fn process(p: Point) i32 {
    return p.x + p.y
}

pub fn main() i32 {
    let val: i32 = 42
    process(val)  // ERROR: mismatched types - expected Point, found i32
    return 0
}
