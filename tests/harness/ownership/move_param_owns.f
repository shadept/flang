//! TEST: move_param_owns
//! EXIT: 3

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
    h.fd = h.fd + 1
    let g = move h
    return g.close() - 1
}

// A `move T` parameter is a binding the function owns.
pub fn main() i32 {
    return keep(open(3))
}
