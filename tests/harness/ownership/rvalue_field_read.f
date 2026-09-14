//! TEST: rvalue_field_read
//! COMPILE-ERROR: E2132
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

pub fn main() i32 {
    return open(3).fd              // error E2132
}
