//! TEST: return_local_moves
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

// A returned binding can only mean a move.
fn make() FileHandle {
    let h = open(3)
    return h
}

pub fn main() i32 {
    return close(make())
}
