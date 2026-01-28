//! TEST: dict_basic
//! EXIT: 30

import std.dict
import std.option

pub fn main() i32 {
    let dict: Dict(i32, i32)

    // Test set and get
    dict.set(1, 10)
    dict.set(2, 20)

    let v1: i32? = dict.get(1)
    let v2: i32? = dict.get(2)

    let val1: i32 = unwrap_or(v1, 0)
    let val2: i32 = unwrap_or(v2, 0)

    // Test contains
    if (dict.contains(1) == false) {
        return 1
    }
    if (dict.contains(99) == true) {
        return 2
    }

    // Test len
    let len1: usize = dict.len()
    if (len1 != 2) {
        return 3
    }

    // Clean up
    dict.deinit()

    // 10 + 20 = 30
    return val1 + val2
}
