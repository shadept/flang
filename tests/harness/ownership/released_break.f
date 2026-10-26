//! TEST: released_break
//! COMPILE-WARNING: W2006 `h` is never released: it is still live at this `break`
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
    loop {
        let h = open(3)
        break // warning W2006
    }
    return 0
}
