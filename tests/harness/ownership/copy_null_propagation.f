//! TEST: copy_null_propagation
//! COMPILE-ERROR: E2158
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
    let p = Holder { h = open(3) }
    let r: &Holder? = Some(&p)
    let x = r?.h                       // error E2158: the payload is a copy of `p.h`
    return 0
}
