//! TEST: read_then_move_in_arg_list
//! EXIT: 6
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

fn take(n: i32, h: FileHandle) i32 {
    return h.fd + n
}

// The read happens before the move, so this compiles (spec 5.1.1).
pub fn main() i32 {
    let h = open(3)
    return take(h.fd, move h)
}
