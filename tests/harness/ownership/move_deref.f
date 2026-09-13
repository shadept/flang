//! TEST: move_deref
//! COMPILE-ERROR: E2125 `move` takes from
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

// A local reference is not a place `move` takes from (RFC-032): the storage behind it belongs to
// whoever holds the `owned` field, and only that module can take the element out.
pub fn main() i32 {
    let h = open(3)
    let p = &h
    return close(move p.*)
}
