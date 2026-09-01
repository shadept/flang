//! TEST: consuming_receiver_parenthesised
//! COMPILE-ERROR: E2128
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

// The rule is about the receiver POSITION, not about `move`: parenthesising the
// transfer does not create a receiver form that the language does not have.
pub fn main() i32 {
    let h = open(3)
    return (move h).close()
}
