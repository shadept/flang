//! TEST: consuming_receiver_parenthesised
//! COMPILE-ERROR: E2128 already consumes
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

// The receiver position is already the move; the language has no second spelling of it.
pub fn main() i32 {
    let h = open(3)
    return (move h).close()
}
