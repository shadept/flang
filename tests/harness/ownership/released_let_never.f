//! TEST: released_let_never
//! COMPILE-WARNING: W2006 `h` is never released: it is still live at this `return`
//! EXIT: 3

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
    let h = open(3)
    return h.fd // warning W2006: `h` is still live
}
