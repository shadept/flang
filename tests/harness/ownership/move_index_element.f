//! TEST: move_index_element
//! COMPILE-ERROR: E2125 `move` takes from
//! EXIT: 1

import std.collections.list

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// `xs[i]` desugars to the ref-form operator: a `&T` into the list's storage, which is the list's to
// hand over (`pop`, `drain`), not the caller's to move from (RFC-032).
pub fn main() i32 {
    let xs: List(FileHandle) = list(2)
    xs.push(open(3))
    return close(move xs[0])
}
