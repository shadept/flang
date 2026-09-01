//! TEST: move_twice_one_call
//! COMPILE-ERROR: E2123
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

fn pair(a: FileHandle, b: FileHandle) i32 {
    return a.fd + b.fd
}

pub fn main() i32 {
    let h = open(3)
    return pair(move h, move h)    // error E2123 on the second
}
