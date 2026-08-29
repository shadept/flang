//! TEST: assign_over_moved_binding_ok
//! EXIT: 4
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

// The counterpart of assign_over_live_binding: after a move, assignment is fine.
pub fn main() i32 {
    let h = open(3)
    close(move h)
    h = open(4)
    return close(move h)
}
