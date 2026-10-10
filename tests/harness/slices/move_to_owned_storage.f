//! TEST: move_to_owned_storage
//! EXIT: 3

import std.string

// A module moves non-copyable elements within storage it owns: removing the front shifts the rest
// down with one `move_to`, through a slice of its `owned` pointer.
type Ring = struct {
    owned ptr: &OwnedString
    len: usize
}

fn drop_front(self: &Ring) {
    let first = move self.ptr.*
    first.deinit()
    const n = self.len - 1
    move_to(slice_from_raw_parts(self.ptr + 1usize, n), slice_from_raw_parts(self.ptr, n))
    self.len = n
}

pub fn main() i32 {
    let backing: [OwnedString; 3] = [from_view("a"), from_view("bb"), from_view("ccc")]
    let r = Ring { ptr = &backing[0], len = 3 }
    drop_front(&r)
    const n = ((r.ptr + 0usize).*.len + (r.ptr + 1usize).*.len) as i32 - 2
    let x = move (r.ptr + 0usize).*
    let y = move (r.ptr + 1usize).*
    x.deinit()
    y.deinit()
    return n
}
