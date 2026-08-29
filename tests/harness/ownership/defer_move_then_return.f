//! TEST: defer_move_then_return
//! COMPILE-ERROR: E2122 was moved
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

fn deinit(self: FileHandle) {}

pub fn main() i32 {
    let h = open(3)
    defer (move h).deinit()
    return close(move h)           // error E2122: `h` is moved twice
}
