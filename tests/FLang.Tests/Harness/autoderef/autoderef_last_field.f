//! TEST: autoderef_last_field
//! EXIT: 99

struct Large {
    a: i32,
    b: i32,
    c: i32,
    d: i32,
    e: i32
}

pub fn getLast(s: &Large) i32 {
    // Access last field in struct with 5 fields
    return s.e
}

pub fn main() i32 {
    let s: Large = Large { a = 1, b = 2, c = 3, d = 4, e = 99 }
    return getLast(&s)
}
