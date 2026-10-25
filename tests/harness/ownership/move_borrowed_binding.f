//! TEST: move_borrowed_binding
//! COMPILE-ERROR: E2131
//! EXIT: 1

import std.option

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn take(o: &Option(FileHandle)) i32 {
    let x = o.* match {
        Some(v) => move v              // error E2131: `v` names storage behind `o`
        None => open(0)
    }
    return x.fd
}

pub fn main() i32 {
    let o: FileHandle? = Some(open(3))
    return take(&o)
}
