//! TEST: op_try_option_basic
//! EXIT: 0

import std.option

fn first_nonzero(xs: i32[]) i32? {
    for x in xs {
        if x != 0 { return Some(x) }
    }
    return None
}

fn doubled_nonzero(xs: i32[]) i32? {
    let v = first_nonzero(xs)?
    return Some(v * 2)
}

pub fn main() i32 {
    let xs: i32[] = [0, 0, 7, 1]
    let result = doubled_nonzero(xs)
    if result.is_none() { return 1 }
    if result.unwrap() != 14 { return 2 }

    let empty: i32[] = []
    let none_result = doubled_nonzero(empty)
    if none_result.is_some() { return 3 }

    return 0
}
