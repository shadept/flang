//! TEST: consuming_receiver_chained
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

// An rvalue receiver carries no move obligation: the callee becomes the owner.
pub fn main() i32 {
    return open(3).close()
}
