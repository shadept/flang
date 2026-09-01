//! TEST: defer_move_twice
//! COMPILE-ERROR: E2123
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

fn deinit(self: FileHandle) {}

pub fn main() i32 {
    let h = open(3)
    defer deinit(move h)
    defer deinit(move h)        // error E2123
    return 0
}
