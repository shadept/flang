//! TEST: receiver_index_element
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

// An index receiver follows the `move` operand table (RFC-032): `xs[0].close()` is refused where
// `move xs[0]` is.
pub fn main() i32 {
    let xs = [open(3)]
    return xs[0].close()
}
