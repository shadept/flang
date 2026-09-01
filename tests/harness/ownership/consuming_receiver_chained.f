//! TEST: consuming_receiver_chained
//! COMPILE-ERROR: E2128
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

// An rvalue receiver carries no move obligation, and is refused all the same: the
// test is the callee's first parameter, so the rule needs no lvalue test of its
// own. Write `close(open(3))`.
pub fn main() i32 {
    return open(3).close()
}
