//! TEST: read_param_cannot_return
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

fn pass_on(h: FileHandle) FileHandle {
    return h                       // error E2131: returning `h` needs a copy
}

pub fn main() i32 {
    let h = open(3)
    return close(pass_on(h))
}
