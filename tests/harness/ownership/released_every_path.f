//! TEST: released_every_path
//! NO-COMPILE-WARNING: W2006 `k`
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

fn both(ok: bool) i32 {
    let k = open(3)
    if ok {
        return close(k)
    }
    return close(k)
}

pub fn main() i32 {
    return both(true)
}
