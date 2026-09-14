//! TEST: move_ref_param
//! COMPILE-ERROR: E2130
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

// A reference is copyable; owning it says nothing about the value it refers to.
fn keep(h: move &FileHandle) i32 {
    return h.fd
}

pub fn main() i32 {
    let h = open(3)
    return keep(&h)
}
