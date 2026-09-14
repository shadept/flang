//! TEST: rvalue_to_read_param
//! COMPILE-ERROR: E2132
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

fn peek(h: FileHandle) i32 {
    return h.fd
}

pub fn main() i32 {
    return peek(open(3))           // error E2132: `FileHandle` reaches no owner
}
