//! TEST: copy_array_repeat_move
//! COMPILE-ERROR: E2158
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

pub fn main() i32 {
    let h = open(3)
    let a = [move h; 2]                // error E2158: `move` does not avoid the copy
    return a[0].fd
}
