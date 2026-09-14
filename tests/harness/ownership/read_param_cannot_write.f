//! TEST: read_param_cannot_write
//! COMPILE-ERROR: E2131
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

fn reset(h: FileHandle) i32 {
    h.fd = 0                       // error E2131: writing `h` needs a copy
    return 0
}

pub fn main() i32 {
    let h = open(3)
    return reset(h)
}
