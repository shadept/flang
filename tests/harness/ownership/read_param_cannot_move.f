//! TEST: read_param_cannot_move
//! COMPILE-ERROR: E2131 declare `h: move FileHandle`
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

fn keep(h: FileHandle) i32 {
    return h.close()               // error E2131: `h` is not owned here
}

pub fn main() i32 {
    let h = open(3)
    return keep(h)
}
