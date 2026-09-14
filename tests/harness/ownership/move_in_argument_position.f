//! TEST: move_in_argument_position
//! COMPILE-ERROR: E2129
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
    let h = open(3)
    return close(move h)           // error E2129: the parameter already says `move`
}
