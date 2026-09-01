//! TEST: use_after_move_deinit
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
    deinit(move h)
    return h.fd                    // error E2123
}
