//! TEST: closure_capture_cannot_move
//! COMPILE-ERROR: E2131 captured
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

// A capture is a reference to the outer binding: the closure cannot take the value out of it.
pub fn main() i32 {
    let h = open(3)
    let f = { => h.close() }  // error E2131
    return f()
}
