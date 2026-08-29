//! TEST: move_match_result
//! COMPILE-ERROR: E2124
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
    let n = move (h.fd match { 0 => 1, else => 2 })   // error E2124
    return 0
}
