//! TEST: move_then_lend_owned_field
//! COMPILE-ERROR: E2133
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

fn take(h: move FileHandle, n: i32) i32 {
    return h.fd + n
}

// The call receives its arguments together, so order does not matter.
pub fn main() i32 {
    let h = open(3)
    return take(h, h.fd)           // error E2133
}
