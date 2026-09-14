//! TEST: move_in_both_branches_unused_after
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

// Moved on every path and never used afterwards: no error.
pub fn main() i32 {
    let h = open(3)
    if h.fd > 0 {
        return h.close()
    } else {
        return h.close()
    }
}
