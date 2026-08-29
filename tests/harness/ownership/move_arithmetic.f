//! TEST: move_arithmetic
//! COMPILE-ERROR: E2124
//! EXIT: 1
//! SKIP: RFC-027 not implemented

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

pub fn main() i32 {
    let a = 1
    let b = 2
    let n = move (a + b)               // error E2124
    return 0
}
