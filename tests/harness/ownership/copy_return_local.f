//! TEST: copy_return_local
//! COMPILE-ERROR: E2123
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

fn make() FileHandle {
    let h = open(3)
    return h                       // error E2123: needs `move h`
}

pub fn main() i32 {
    return close(make())
}
