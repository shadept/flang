//! TEST: return_local_implicit
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

// The trailing expression of a body is its return value, so a binding there moves too.
fn make(n: i32) FileHandle {
    let h = open(n)
    if n > 5 {
        return open(0)
    }
    h
}

pub fn main() i32 {
    return close(make(3))
}
