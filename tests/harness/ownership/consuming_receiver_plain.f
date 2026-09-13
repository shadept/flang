//! TEST: consuming_receiver_plain
//! EXIT: 3

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

// The receiver of a by-value first parameter is the inferred `move` (spec 7.2).
pub fn main() i32 {
    let h = open(3)
    return h.close()               // moves `h`
}
