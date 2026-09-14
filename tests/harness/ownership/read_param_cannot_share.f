//! TEST: read_param_cannot_share
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

fn hit(h: &FileHandle) i32 {
    return h.fd
}

fn share(h: FileHandle) i32 {
    return hit(&h)                 // error E2131: `h` is not the function's to share
}

pub fn main() i32 {
    let h = open(3)
    return share(h)
}
