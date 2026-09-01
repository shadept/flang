//! TEST: move_copyable_field
//! COMPILE-WARNING: W2005
//! EXIT: 3

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// `fd` is an i32. Moving it transfers nothing.
pub fn main() i32 {
    let h = open(3)
    let n = move h.fd              // warning W2005
    return n
}
