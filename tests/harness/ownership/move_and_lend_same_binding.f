//! TEST: move_and_lend_same_binding
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

fn h2(a: FileHandle, b: move FileHandle) i32 {
    return a.fd + b.fd
}

pub fn main() i32 {
    let x = open(3)
    return h2(x, x)                // error E2133: lent to `a`, moved into `b`
}
