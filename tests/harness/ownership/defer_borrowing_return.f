//! TEST: defer_borrowing_return
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

fn deinit(self: FileHandle) {}

fn peek(h: &FileHandle) i32 {
    return h.fd
}

// The return expression BORROWS, so the deferred move is still valid.
pub fn main() i32 {
    let h = open(3)
    defer deinit(move h)
    return peek(&h)
}
