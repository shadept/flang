//! TEST: move_and_lend_owned_field
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

fn take(n: i32, h: move FileHandle) i32 {
    return h.fd + n
}

// `fd` is `owned`: the callee would release it while also reading it.
pub fn main() i32 {
    let h = open(3)
    return take(h.fd, h)           // error E2133
}
