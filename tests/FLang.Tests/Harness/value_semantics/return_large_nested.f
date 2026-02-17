//! TEST: return_large_nested
//! EXIT: 0

// Returning large structs through nested function calls.
// Each return uses a hidden return slot — must not corrupt other slots.

type Point3D = struct {
    x: i32,
    y: i32,
    z: i32
}

fn make(x: i32, y: i32, z: i32) Point3D {
    Point3D { x = x, y = y, z = z }
}

fn add(a: Point3D, b: Point3D) Point3D {
    make(a.x + b.x, a.y + b.y, a.z + b.z)
}

fn negate(p: Point3D) Point3D {
    make(0 - p.x, 0 - p.y, 0 - p.z)
}

pub fn main() i32 {
    let a = make(1, 2, 3)
    let b = make(10, 20, 30)

    // Nested: add(a, negate(b)) = (1-10, 2-20, 3-30) = (-9, -18, -27)
    let c = add(a, negate(b))
    if c.x != -9 { return 1 }
    if c.y != -18 { return 2 }
    if c.z != -27 { return 3 }

    // Double negate should be identity
    let d = negate(negate(a))
    if d.x != 1 { return 4 }
    if d.y != 2 { return 5 }
    if d.z != 3 { return 6 }

    return 0
}
