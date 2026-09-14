//! TEST: rvalue_read_receiver
//! COMPILE-ERROR: E2132
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

fn hit(self: &FileHandle) i32 {
    return self.fd
}

pub fn main() i32 {
    return open(3).hit()           // error E2132
}
