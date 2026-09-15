//! TEST: stdlib_dict_grows_owners
//! EXIT: 210

import std.collections.dict
import std.option

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

// Growing the table hands every entry to the new buffer.
pub fn main() i32 {
    let d: Dict(i32, FileHandle) = dict()
    for i in 0..21 {
        d.set(i, open(i))
    }
    let total = 0
    for i in 0..21 {
        total = total + d.get_ref(i).unwrap().fd
    }
    return total
}
