//! TEST: dict_remove
//! SKIP: Blocked by lack of while loop support in FLang

// Dict implementation requires while loops for hash table probing.
// FLang currently only supports for-in loops over iterables.
// Once while loops are added, this test should EXIT: 10

import std.dict
import std.option

pub fn main() i32 {
    let dict: Dict(i32, i32) = dict_new(i32, i32)

    dict.set(1, 10)
    dict.set(2, 20)
    dict.set(3, 30)

    // Remove key 2
    let removed: i32? = dict.remove(2)
    let removed_val: i32 = unwrap_or(removed, 0)
    if (removed_val != 20) {
        return 1
    }

    // Verify it's gone
    if (dict.contains(2) == true) {
        return 2
    }

    // Verify len decreased
    let len1: usize = dict.len()
    if (len1 != 2) {
        return 3
    }

    // Verify other keys still work
    let v1: i32? = dict.get(1)
    let val1: i32 = unwrap_or(v1, 0)
    if (val1 != 10) {
        return 4
    }

    // Remove non-existent key returns null
    let removed2: i32? = dict.remove(99)
    if (removed2.has_value == true) {
        return 5
    }

    dict.deinit()

    return val1
}
