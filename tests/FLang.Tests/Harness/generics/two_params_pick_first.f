//! TEST: generics_two_params_pick_first
//! EXIT: 7

pub fn pick_first(a: $T, b: $U) T {
    return a
}

pub fn main() i32 {
    let x: i32 = pick_first(7, true)
    return x
}
