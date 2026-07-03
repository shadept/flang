//! TEST: multiple_params_independent
//! EXIT: 0

// When the same value is passed to multiple parameters,
// each parameter gets its own copy/reference. Mutations are independent.

type Vec2 = struct {
    x: i32,
    y: i32
}

fn both_mutate(a: Vec2, b: Vec2) i32 {
    a.x = 100
    b.x = 200
    a.x + b.x
}

fn pass_twice(v: Vec2) i32 {
    both_mutate(v, v)
}

pub fn main() i32 {
    let v = Vec2 { x = 1, y = 2 }
    let result = pass_twice(v)

    // Caller's value must be unchanged
    if v.x != 1 { return 1 }
    if v.y != 2 { return 2 }

    // Both params got independent COW copies
    if result != 300 { return 3 }

    return 0
}
