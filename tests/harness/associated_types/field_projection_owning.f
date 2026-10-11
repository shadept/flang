//! TEST: field_projection_owning
//! COMPILE-ERROR: E2124
//! EXIT: 1

import std.option

type Handle = struct {
    owned fd: i32
}

pub fn deinit(self: move Handle) {}

type Handles = struct {
    left: i32
}

fn next(self: &Handles) Handle? {
    return null
}

type Iter = contract {
    type Item
    fn next(self: &Self) Item?
}

type Peekable = struct(I: Iter) {
    it: I
    peeked: I.Item?
}

pub fn main() i32 {
    let p: Peekable(Handles) = .{ it = Handles { left = 0 }, peeked = null }
    let q = p // error E2124: `peeked` holds an owning `Handle`
    return 0
}
