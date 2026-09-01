//! TEST: reinit_after_move
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

// Assignment over a MOVED binding reinitializes it and makes it live again.
pub fn main() i32 {
    let h = open(4)
    close(move h)
    h = open(3)
    return h.fd
}
