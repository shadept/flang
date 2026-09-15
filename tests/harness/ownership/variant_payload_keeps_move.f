//! TEST: variant_payload_keeps_move
//! COMPILE-ERROR: E2124
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

// A variant payload is a by-value destination like a struct literal field: it keeps `move`.
pub fn main() i32 {
    let a = open(3)
    let b = open(4)
    let x: FileHandle? = Some(move a)
    let y: FileHandle? = Some(b)   // error E2124
    return 0
}
