//! TEST: struct_large_pass_return
//! EXIT: 42

// Test implicit reference passing for large structs (> 8 bytes).
// Exercises: large struct param by-ref, large struct return via hidden slot,
// copy-on-write (mutation of large param), and nested calls.

type Vec3 = struct {
    x: i32,
    y: i32,
    z: i32
}

fn make_vec(x: i32, y: i32, z: i32) Vec3 {
    Vec3 { x = x, y = y, z = z }
}

fn sum(v: Vec3) i32 {
    v.x + v.y + v.z
}

fn scale(v: Vec3, s: i32) Vec3 {
    make_vec(v.x * s, v.y * s, v.z * s)
}

fn add(a: Vec3, b: Vec3) Vec3 {
    make_vec(a.x + b.x, a.y + b.y, a.z + b.z)
}

// Test mutation of a large value param (copy-on-write)
fn with_x(v: Vec3, new_x: i32) Vec3 {
    v.x = new_x
    v
}

pub fn main() i32 {
    let a = make_vec(1, 2, 3)      // 12 bytes, passed by implicit ref
    let b = scale(a, 2)             // returns via hidden return slot
    let c = add(a, b)               // both args by-ref, return via slot
    let d = with_x(c, 10)           // copy-on-write of large param
    // d = Vec3 { x=10, y=6, z=9 }
    // sum(d) = 10 + 6 + 9 = 25

    // Nested call: sum(add(a, d))
    // a = {1,2,3}, d = {10,6,9}
    // add = {11,8,12}, sum = 31
    let e = sum(add(a, d))

    // Verify small struct still works by value
    if e != 31 { return 1 }
    if sum(a) != 6 { return 2 }
    if sum(b) != 12 { return 3 }
    if sum(d) != 25 { return 4 }

    // Final: return 42 on success
    return 42
}
