//! TEST: read_param_cannot_assign
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

fn swap_in(h: FileHandle) i32 {
    h = open(4)                    // error E2131
    return 0
}

pub fn main() i32 {
    let h = open(3)
    return swap_in(h)
}
