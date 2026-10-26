//! TEST: released_tuple_parts
//! NO-COMPILE-WARNING: W2006 `t`
//! EXIT: 7

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    const fd = h.fd
    leak(h)
    return fd
}

// A tuple is released element by element.
pub fn main() i32 {
    let t = (open(3), open(4))
    const a = close(t.0)
    const b = close(t.1)
    return a + b
}
