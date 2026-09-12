//! TEST: if_directive_type_param_copyable
//! EXIT: 12

// `#if type_info(T).copyable` inside a generic body decides per specialization: the bit is derived
// from the concrete type bound to `T` (RFC-028), so a struct with an `owned` field takes the other
// branch than an integer does.

import core.rtti

type FileHandle = struct {
    owned fd: i32
}

fn probe(x: &$T) i32 {
    #if type_info(T).copyable {
        return 2
    } else {
        return 10
    }
}

pub fn main() i32 {
    let n: i32 = 7
    let h = FileHandle { fd = 3 }
    return probe(&n) + probe(&h)
}
