//! TEST: rvalue_argument
//! EXIT: 3

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// A call result has no place to move from, so no `move` is required.
pub fn main() i32 {
    return close(open(3))
}
