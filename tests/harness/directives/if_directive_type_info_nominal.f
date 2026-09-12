//! TEST: if_directive_type_info_nominal
//! EXIT: 3

// `type_info(Name)` in a `#if` works on any non-generic nominal visible from the module, not only on
// a type parameter: the compiler knows the type either way.

import core.rtti

type FileHandle = struct {
    owned fd: i32
}

type Point = struct {
    x: i32
}

pub fn main() i32 {
    let score: i32 = 0
    #if type_info(Point).copyable {
        score = score + 1
    }
    #if !type_info(FileHandle).copyable {
        score = score + 2
    }
    #if type_info(FileHandle).kind == TypeKind.Enum {
        score = score + 4
    }
    return score
}
