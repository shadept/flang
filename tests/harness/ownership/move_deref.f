//! TEST: move_deref
//! EXIT: 3

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// Moving through a pointer is unchecked: there is no binding to kill.
pub fn main() i32 {
    let h = open(3)
    let p = &h
    return close(move p.*)
}
