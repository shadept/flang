//! TEST: closure_capture_lent_param
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

// A parameter without `move` stays read-only through a capture.
fn reset(h: FileHandle) i32 {
    let f = fn() { h.fd = 0 }       // error E2131
    f()
    return h.fd
}

pub fn main() i32 {
    let h = open(3)
    return reset(h)
}
