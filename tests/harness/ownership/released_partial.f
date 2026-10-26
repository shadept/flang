//! TEST: released_partial
//! COMPILE-WARNING: W2006 `p` is never released: part of it was moved out
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

type Pair = struct {
    a: FileHandle
    b: FileHandle
}

pub fn main() i32 {
    let p = Pair { a = open(1), b = open(2) }
    const _fd = close(p.a)
    return 0 // warning W2006: `p.b` is still live
}
