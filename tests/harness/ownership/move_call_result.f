//! TEST: move_call_result
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
    let n = move open(3)               // error E2124: a call result is not a place
    return 0
}
