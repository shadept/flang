//! TEST: copy_struct_literal_field
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

type Wrapper = struct {
    inner: FileHandle
}

pub fn main() i32 {
    let h = open(3)
    let w = Wrapper { inner = h }      // error E2123: needs `move h`
    return w.inner.fd
}
