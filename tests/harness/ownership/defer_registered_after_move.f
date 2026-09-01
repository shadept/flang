//! TEST: defer_registered_after_move
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
    close(move h)
    defer deinit(move h)        // error E2123: already moved when the body runs
    return 0
}
