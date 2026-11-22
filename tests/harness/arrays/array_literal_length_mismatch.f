//! TEST: array_literal_length_mismatch
//! COMPILE-ERROR: E2011
//! EXIT: 1

// A literal at an array parameter must have the parameter's length: a shorter one fits no
// overload, as an array value of that length would not.

fn first_of(xs: [i64; 3]) i64 {
    return xs[0]
}

pub fn main() i32 {
    return first_of([1i64, 2]) as i32
}
