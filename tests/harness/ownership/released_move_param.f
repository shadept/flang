//! TEST: released_move_param
//! COMPILE-WARNING: W2006 `s` is never released
//! EXIT: 1

import std.string

fn len_of(s: move OwnedString) usize {
    return s.view().len // warning W2006: the function owns `s`
}

pub fn main() i32 {
    return len_of(from_view("x")) as i32
}
