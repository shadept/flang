//! TEST: copy_call_argument
//! COMPILE-ERROR: E2124
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
    let h = open(3)
    return close(h)                    // error E2124: needs `move h`
}
