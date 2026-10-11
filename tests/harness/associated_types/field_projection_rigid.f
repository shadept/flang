//! TEST: field_projection_rigid
//! COMPILE-ERROR: E2124
//! EXIT: 1

import std.option

type Iter = contract {
    type Item
    fn next(self: &Self) Item?
}

type Peekable = struct(I: Iter) {
    it: I
    peeked: I.Item?
}

// Inside the generic body `self.peeked` is `I.Item?`, copyable only under `I.Item: copyable`.
fn peek(self: &Peekable($I)) I.Item? {
    return self.peeked // error E2124
}

pub fn main() i32 {
    return 0
}
