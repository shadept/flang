//! TEST: copy_array_literal_element
//! COMPILE-ERROR: E2124
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

pub fn main() i32 {
    let h = open(3)
    let xs: [FileHandle; 2] = [h, open(4)]   // error E2124: needs `move h`
    return 0
}
