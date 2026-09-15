//! TEST: closure_capture_writes_owned
//! EXIT: 4

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

// A closure writes a non-copyable local it captures, in place.
pub fn main() i32 {
    let h = open(3)
    let bump = fn() { h.fd = h.fd + 1 }
    bump()
    return h.close()
}
