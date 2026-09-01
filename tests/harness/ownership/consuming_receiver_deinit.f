//! TEST: consuming_receiver_deinit
//! COMPILE-ERROR: E2128
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

fn deinit(self: FileHandle) {}

pub fn main() i32 {
    let h = open(3)
    h.deinit()                     // error E2128: write `deinit(move h)`
    return 0
}
