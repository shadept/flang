//! TEST: defer_unrelated_value
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

let counter: i32 = 0

fn bump() {
    counter = counter + 1
}

// A defer that names nothing owned is unaffected by any move.
pub fn main() i32 {
    let h = open(3)
    defer bump()
    return close(move h)
}
