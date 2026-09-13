//! TEST: consuming_receiver_deinit
//! EXIT: 0

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: FileHandle) i32 {
    return h.fd
}

fn deinit(self: FileHandle) {}

pub fn main() i32 {
    let h = open(3)
    h.deinit()                     // moves `h`
    return 0
}
