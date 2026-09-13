//! TEST: receiver_through_reference
//! COMPILE-ERROR: E2128 reached through a reference
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

// A `&FileHandle` receiver adapting to the by-value parameter would read the value out of storage
// this function does not own.
fn peek(h: &FileHandle) i32 {
    return h.close()
}

pub fn main() i32 {
    let h = open(3)
    let n = peek(&h)
    return n + h.fd
}
