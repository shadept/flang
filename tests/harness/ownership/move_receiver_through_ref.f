//! TEST: move_receiver_through_ref
//! COMPILE-ERROR: E2128
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

// A `move self` parameter is not reachable through a `&T` receiver: the pointee stays owned by `h`.
pub fn main() i32 {
    let h = open(3)
    let p = &h
    return p.close()               // error E2128
}
