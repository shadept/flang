//! TEST: return_move_redundant
//! COMPILE-WARNING: I2001 redundant
//! EXIT: 3

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

fn make() FileHandle {
    let h = open(3)
    return move h                  // info I2001: `return h` already moves
}

pub fn main() i32 {
    return close(make())
}
