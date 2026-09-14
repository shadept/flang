//! TEST: move_and_share_same_binding
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

fn j(a: &FileHandle, b: move FileHandle) i32 {
    return a.fd + b.fd
}

pub fn main() i32 {
    let x = open(3)
    return j(&x, x)                // error E2133
}
