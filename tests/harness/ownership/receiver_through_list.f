//! TEST: receiver_through_list
//! COMPILE-ERROR: E2128 reached through a reference
//! EXIT: 1

import std.collections.list

// `List` reaches its storage through `op_deref`; a consumer of the storage itself is not reachable
// as a method of the list.
fn drain(xs: UnmanagedList(i32)) usize {
    return xs.len
}

pub fn main() i32 {
    let l: List(i32) = list(1)
    defer l.deinit()
    return l.drain() as i32
}
