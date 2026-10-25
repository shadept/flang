//! TEST: struct_shorthand_move
//! EXIT: 3

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

type Holder = struct {
    h: FileHandle
    n: i32
}

pub fn main() i32 {
    let h = open(3)
    let p = Holder { move h, n = 0i32 }  // `h = move h`
    return p.h.fd
}
