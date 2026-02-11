//! TEST: large_struct_cow
//! EXIT: 0
//! STDOUT: 1
//! STDOUT: 99

// Copy-on-write for large structs passed by implicit reference.
// Writing to a by-ref param must create a local shadow copy.

struct Matrix {
    m00: i32,
    m01: i32,
    m10: i32,
    m11: i32
}

fn set_diagonal(m: Matrix, val: i32) Matrix {
    m.m00 = val        // triggers copy-on-write
    m.m11 = val        // writes to local shadow
    m
}

pub fn main() i32 {
    let identity = Matrix { m00 = 1, m01 = 0, m10 = 0, m11 = 1 }
    let scaled = set_diagonal(identity, 99)

    println(identity.m00) // must still be 1
    println(scaled.m00)    // must be 99

    if identity.m00 != 1 { return 1 }
    if identity.m11 != 1 { return 2 }
    if scaled.m00 != 99 { return 3 }
    if scaled.m11 != 99 { return 4 }
    if scaled.m01 != 0 { return 5 }  // unmodified fields preserved

    return 0
}
