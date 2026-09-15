//! TEST: move_param_named_argument
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

// A named argument fills its parameter's mode like a positional one.
pub fn main() i32 {
    let g = open(3)
    let n = close(h = g)
    return n + g.fd                // error E2123
}
