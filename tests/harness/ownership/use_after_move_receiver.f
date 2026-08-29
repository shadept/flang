//! TEST: use_after_move_receiver
//! COMPILE-ERROR: E2122
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
    let h = open(3)
    (move h).close()
    return h.fd                        // error E2122
}
