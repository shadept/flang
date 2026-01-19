//! TEST: autoderef_mixed_sizes
//! EXIT: 77

struct Mixed {
    a: u8,
    b: i32,
    c: u8,
    d: i64
}

pub fn getThird(m: &Mixed) i32 {
    // Access third field (c) after different-sized fields
    // Tests proper offset calculation with alignment
    return m.c as i32
}

pub fn getFourth(m: &Mixed) i32 {
    // Access fourth field (d) - i64 after mixed sizes
    return m.d as i32
}

pub fn main() i32 {
    let m: Mixed = Mixed { a = 1, b = 2, c = 77, d = 100 }
    return getThird(&m)
}
