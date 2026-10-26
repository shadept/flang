//! TEST: released_loop_never_exits
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

// A `loop` with no `break` leaves only by `return`: nothing after it runs.
fn first() i32 {
    let h = open(3)
    loop {
        return close(h)
    }
    return 0
}

pub fn main() i32 {
    return first()
}
