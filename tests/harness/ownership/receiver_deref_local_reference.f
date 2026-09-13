//! TEST: receiver_deref_local_reference
//! COMPILE-ERROR: E2125 belongs to its container
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

// The inferred receiver move follows the `move` operand table: `p.*.close()` is refused where
// `close(move p.*)` is.
pub fn main() i32 {
    let h = open(3)
    let p = &h
    return p.*.close()
}
