//! TEST: move_then_read_in_arg_list
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

fn take(h: FileHandle, n: i32) i32 {
    return h.fd + n
}

// Arguments evaluate left to right (spec 5.1.1), so `h.fd` reads a moved
// binding.
pub fn main() i32 {
    let h = open(3)
    return take(move h, h.fd)      // error E2122
}
