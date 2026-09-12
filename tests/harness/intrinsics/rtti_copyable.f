//! TEST: rtti_copyable
//! EXIT: 5

// `TypeInfo.copyable` at run time is the derived bit of RFC-028, filled from the same walk the
// checker uses: an `owned` field clears it, and it propagates through a by-value field.

import core.rtti

type FileHandle = struct {
    owned fd: i32
}

type Session = struct {
    handle: FileHandle
    id: i32
}

type Point = struct {
    x: i32
}

pub fn main() i32 {
    let score: i32 = 0
    if type_info(i32).copyable {
        score = score + 1
    }
    if type_info(Point).copyable {
        score = score + 4
    }
    if type_info(FileHandle).copyable {
        score = score + 16
    }
    if type_info(Session).copyable {
        score = score + 64
    }
    return score
}
