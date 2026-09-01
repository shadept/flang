//! TEST: borrow_stays_live
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

fn peek(h: &FileHandle) i32 {
    return h.fd
}

// A borrow does not move.
pub fn main() i32 {
    let h = open(3)
    let a = peek(&h)
    return h.fd + a - a
}
