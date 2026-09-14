//! TEST: defer_move_then_return
//! COMPILE-ERROR: E2123 was moved
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

fn deinit(self: move FileHandle) {}

pub fn main() i32 {
    let h = open(3)
    defer h.deinit()
    return h.close()               // error E2123: `h` is moved twice
}
