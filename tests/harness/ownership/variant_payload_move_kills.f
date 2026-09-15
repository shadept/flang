//! TEST: variant_payload_move_kills
//! COMPILE-ERROR: E2123
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

pub fn main() i32 {
    let a = open(3)
    let x: FileHandle? = Some(move a)
    return a.fd                    // error E2123
}
