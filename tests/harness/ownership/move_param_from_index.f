//! TEST: move_param_from_index
//! COMPILE-ERROR: E2125
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

// The element stays in the array; the callee would be a second owner.
pub fn main() i32 {
    let xs: [FileHandle; 2] = [open(3), open(4)]
    return close(xs[0])            // error E2125
}
