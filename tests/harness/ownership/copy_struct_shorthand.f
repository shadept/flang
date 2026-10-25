//! TEST: copy_struct_shorthand
//! COMPILE-ERROR: E2124
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
    let p = Holder { h }               // error E2124: `Holder { h = h }` copies `h`
    return p.h.fd
}
