//! TEST: move_param_from_deref
//! COMPILE-ERROR: E2125
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

// The pointee stays owned by `h`; nothing is left to take through the reference.
pub fn main() i32 {
    let h = open(3)
    let p = &h
    return close(p.*)              // error E2125
}
