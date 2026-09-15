//! TEST: rvalue_argument
//! EXIT: 3

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

// A temporary goes straight to the `move` parameter.
pub fn main() i32 {
    return close(open(3))
}
