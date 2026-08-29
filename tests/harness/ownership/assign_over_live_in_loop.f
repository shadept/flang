//! TEST: assign_over_live_in_loop
//! COMPILE-ERROR: E2125
//! EXIT: 1
//! SKIP: RFC-027 not implemented

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
    for _i in 0..2 {
        h = open(4)                    // error E2125 on the second iteration
    }
    return 0
}
