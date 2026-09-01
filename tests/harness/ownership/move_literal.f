//! TEST: move_literal
//! COMPILE-ERROR: E2125
//! EXIT: 1

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
    let n = move 3                     // error E2125
    return 0
}
