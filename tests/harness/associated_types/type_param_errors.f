//! TEST: type_param_errors
//! COMPILE-ERROR: E2144
//! EXIT: 1

import std.option

type Iter = contract {
    type Item
    fn next(self: &Self) Item?
}

type Later = struct(F: fn(I.Item) bool, I: Iter) { // error E2144: names the later `I`
    f: F
    it: I
}

pub fn main() i32 {
    return 0
}
