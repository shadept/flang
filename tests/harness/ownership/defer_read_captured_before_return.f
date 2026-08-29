//! TEST: defer_read_captured_before_return
//! EXIT: 3
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

fn log(n: i32) {}

// Reading the field into a local first takes `h` out of the defer body.
pub fn main() i32 {
    let h = open(3)
    let fd = h.fd
    defer log(fd)
    return close(move h)
}
