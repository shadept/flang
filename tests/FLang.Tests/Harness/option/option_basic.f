//! TEST: option_basic
//! EXIT: 17

import std.option

fn maybe_add(flag: bool, value: i32) i32? {
    if (flag) {
        let r: i32? = value
        return r
    }
    return null
}

fn unwrap_or_default(value: i32?, fallback: i32) i32 {
    return unwrap_or(value, fallback)
}

pub fn main() i32 {
    let a: i32? = maybe_add(true, 4)
    let b: i32? = null
    let c: i32? = .{ has_value = true, value = 5 }
    let d: i32? = 5

    let sum: i32 = unwrap_or(a, 0) + unwrap_or(b, 3) + unwrap_or(c, 0) + unwrap_or(d, 0)
    return sum
}
