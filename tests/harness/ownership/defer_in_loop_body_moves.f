//! TEST: defer_in_loop_body_moves
//! COMPILE-ERROR: E2122
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

fn deinit(self: FileHandle) {}

// The body fires once per iteration.
pub fn main() i32 {
    let h = open(3)
    for _i in 0..2 {
        defer (move h).deinit()    // error E2122 on the second iteration
    }
    return 0
}
