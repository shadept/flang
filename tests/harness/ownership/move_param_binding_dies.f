//! TEST: move_param_binding_dies
//! COMPILE-ERROR: E2123
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

fn keep(h: move FileHandle) i32 {
    let n = h.close()
    return n + h.fd                // error E2123
}

pub fn main() i32 {
    return keep(open(3))
}
