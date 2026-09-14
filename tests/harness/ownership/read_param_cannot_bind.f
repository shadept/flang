//! TEST: read_param_cannot_bind
//! COMPILE-ERROR: E2131
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

fn rebind(h: FileHandle) i32 {
    let g = move h                 // error E2131
    return g.close()
}

pub fn main() i32 {
    let h = open(3)
    return rebind(h)
}
