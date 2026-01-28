//! TEST: dict_overwrite
//! EXIT: 42

import std.dict
import std.option

pub fn main() i32 {
    let dict: Dict(i32, i32)

    // Set and overwrite
    dict.set(1, 10)
    dict.set(1, 42)

    let v: i32? = dict.get(1)
    let val: i32 = unwrap_or(v, 0)

    // Length should still be 1
    let l: usize = dict.len()
    if (l != 1) {
        return 1
    }

    dict.deinit()
    return val
}
