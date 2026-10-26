//! TEST: released_loop_body
//! COMPILE-WARNING: W2006 `h` is never released: it is still live at the end of its scope
//! EXIT: 0

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

pub fn main() i32 {
    for i in 0i32..3i32 {
        let h = open(i) // warning W2006: a new `h` leaks each iteration
    }
    return 0
}
