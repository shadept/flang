//! TEST: receiver_move_then_use
//! COMPILE-ERROR: E2123 was moved
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

pub fn main() i32 {
    let h = open(3)
    let n = h.close()              // moves `h`
    return n + h.fd                // error E2123
}
