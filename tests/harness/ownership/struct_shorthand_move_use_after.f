//! TEST: struct_shorthand_move_use_after
//! COMPILE-ERROR: E2123
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

type Holder = struct {
    h: FileHandle
}

pub fn main() i32 {
    let h = open(3)
    let p = Holder { move h }
    return h.fd                        // error E2123
}
