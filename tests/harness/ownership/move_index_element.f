//! TEST: move_index_element
//! EXIT: 3
//! SKIP: RFC-028 step 6 - std.list stores its element without `move`

import std.list

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// `xs[i]` desugars to the ref-form operator, so the move goes through a
// reference and marks no binding.
pub fn main() i32 {
    let xs: List(FileHandle) = list(2)
    xs.push(open(3))
    return close(move xs[0])
}
