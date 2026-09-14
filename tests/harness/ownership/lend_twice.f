//! TEST: lend_twice
//! EXIT: 6

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn close(h: move FileHandle) i32 {
    return h.fd
}

fn sum(a: FileHandle, b: FileHandle) i32 {
    return a.fd + b.fd
}

// Two reads of one value own nothing.
pub fn main() i32 {
    let x = open(3)
    return sum(x, x)
}
