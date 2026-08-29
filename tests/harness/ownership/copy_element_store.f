//! TEST: copy_element_store
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

pub fn main() i32 {
    let h = open(3)
    let xs: [FileHandle; 2]
    xs[0] = h                          // error E2123: needs `move h`
    return 0
}
