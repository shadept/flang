//! TEST: copy_return_local
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

fn make() FileHandle {
    let h = open(3)
    return h                       // error E2124: needs `move h`
}

pub fn main() i32 {
    return close(make())
}
