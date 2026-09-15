//! TEST: stdlib_option_unwrap_moves
//! COMPILE-ERROR: E2123
//! EXIT: 1

import std.option

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

// `unwrap` takes the option apart: the payload leaves it.
pub fn main() i32 {
    let o: FileHandle? = Some(open(3))
    let h = o.unwrap()
    if o.is_some() {               // error E2123
        return 1
    }
    return close(h)
}
