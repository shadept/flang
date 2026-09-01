//! TEST: move_then_ref_param
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

fn peek(h: &FileHandle) i32 {
    return h.fd
}

pub fn main() i32 {
    let h = open(3)
    close(move h)
    return peek(&h)                // error E2123
}
