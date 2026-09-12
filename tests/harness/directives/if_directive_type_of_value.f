//! TEST: if_directive_type_of_value
//! EXIT: 12

// `type_of(v)` in a `#if` is the type of a binding in scope, so a generic body can ask about its
// parameter without naming `T`; `type_info` is for types, `type_of` for values.

import core.rtti

type FileHandle = struct {
    owned fd: i32
}

fn probe(x: $T) i32 {
    #if type_of(x).copyable {
        return 2
    } else {
        return 10
    }
}

pub fn main() i32 {
    // An rvalue argument is a transfer, not a copy, so the non-copyable handle needs no `move`.
    return probe(7i32) + probe(FileHandle { fd = 3 })
}
