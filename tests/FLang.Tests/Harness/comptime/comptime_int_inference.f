//! TEST: comptime_int_inferred_from_function
//! EXIT: 0

fn takes_i16(x: i16) i16 {
    return x
}

pub fn main() i32 {
    let a = 10
    let result = takes_i16(a)
    return 0
}
