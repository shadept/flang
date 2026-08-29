//! TEST: move_arg_runtime
//! EXIT: 3
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

// A move changes no observable behaviour in the callee.
pub fn main() i32 {
    let h = open(3)
    return close(move h)
}
