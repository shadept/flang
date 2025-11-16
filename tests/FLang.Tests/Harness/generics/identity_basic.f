//! TEST: generics_identity_basic
//! EXIT: 42

pub fn identity(x: $T) T {
    return x
}

pub fn main() i32 {
    let v: i32 = identity(42)
    return v
}
