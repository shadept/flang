//! TEST: released_some_paths
//! COMPILE-WARNING: W2006 `h` is not released on every path
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

fn maybe(ok: bool) i32 {
    let h = open(3)
    if ok {
        const _fd = close(h)
    }
    return 0 // warning W2006: live when `ok` is false
}

pub fn main() i32 {
    return maybe(true)
}
