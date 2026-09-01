//! TEST: move_call_result
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
    let n = move open(3)               // error E2125: a call result is not a place
    return 0
}
