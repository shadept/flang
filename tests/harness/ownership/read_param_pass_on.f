//! TEST: read_param_pass_on
//! EXIT: 9

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

fn wrap(h: FileHandle) i32 {
    return peek(h) + h.peek() + h.fd - 2
}

// A non-copyable `T` parameter is read and passed on to another `T` parameter.
pub fn main() i32 {
    let h = open(3)
    return wrap(h) + wrap(h) - h.close() - 2
}
