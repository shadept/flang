//! TEST: return_binding_inferred
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

// `return h` of a non-copyable local is the inferred `move` (spec 7.2).
fn make() FileHandle {
    let h = open(3)
    return h
}

pub fn main() i32 {
    let h = make()
    return h.close()
}
