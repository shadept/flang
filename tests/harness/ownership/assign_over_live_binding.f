//! TEST: assign_over_live_binding
//! COMPILE-ERROR: E2126 is live
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

pub fn main() i32 {
    let h = open(3)
    h = open(4)                        // error E2126: `h` is live, the old value leaks
    return 0
}
