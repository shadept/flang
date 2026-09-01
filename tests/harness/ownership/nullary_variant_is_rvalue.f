//! TEST: nullary_variant_is_rvalue
//! EXIT: 3

import std.option

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

// `None` builds its value where it stands rather than reading it out of storage, so binding it is
// not a copy however non-copyable the enum's other variants are. `is_some` reaches a non-copyable
// receiver because it takes one by reference.
pub fn main() i32 {
    let empty: FileHandle? = None
    if empty.is_some() {
        return 1
    }
    let full: FileHandle? = Some(open(3))
    if full.is_none() {
        return 2
    }
    return full match {
        Some(h) => h.fd
        None => 0
    }
}
