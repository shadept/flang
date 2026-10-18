//! TEST: error_e2156_no_trailing_slot
//! COMPILE-ERROR: E2156

// A trailing lambda needs a callable parameter with only defaulted parameters after it.
fn apply(f: fn(i32) i32, x: i32) i32 {
    return f(x)
}

pub fn main() i32 {
    return apply(3) { x: i32 => x }
}
