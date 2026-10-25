//! TEST: copy_array_repeat
//! COMPILE-ERROR: E2158
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

pub fn main() i32 {
    let a = [open(3); 2]               // error E2158: each element is a copy
    return a[0].fd
}
