//! TEST: released_never_call_diverges
//! NO-COMPILE-WARNING: W2006 `h`
//! EXIT: 3

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

// A call returning `never` ends the path: `h` is not left behind by it.
fn check(bad: bool) i32 {
    let h = open(3)
    if bad {
        panic("bad")
    }
    return close(h)
}

pub fn main() i32 {
    return check(false)
}
