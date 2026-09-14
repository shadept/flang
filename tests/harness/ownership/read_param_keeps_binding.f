//! TEST: read_param_keeps_binding
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

// A `T` parameter reads: the caller's binding is unaffected.
pub fn main() i32 {
    let h = open(3)
    let a = peek(h)
    let b = peek(h)
    return a + b + h.close()
}
