//! TEST: copyable_field_read
//! EXIT: 3
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

// `fd` is a copyable i32, so reading it through a non-copyable value is free.
pub fn main() i32 {
    let h = open(3)
    let a = h.fd
    let b = h.fd
    return a + b - h.fd
}
