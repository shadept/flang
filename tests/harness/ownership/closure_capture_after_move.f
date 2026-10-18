//! TEST: closure_capture_after_move
//! COMPILE-ERROR: E2123
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

// Building the closure reads every name it captures.
pub fn main() i32 {
    let h = open(3)
    let n = h.close()
    let f = { => h.fd }       // error E2123
    return f() + n
}
