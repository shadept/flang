//! TEST: receiver_paren_form
//! EXIT: 3
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

// The explicit spelling for a consuming method call.
pub fn main() i32 {
    let h = open(3)
    return (move h).close()
}
