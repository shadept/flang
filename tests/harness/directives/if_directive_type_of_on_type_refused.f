//! TEST: if_directive_type_of_on_type_refused
//! COMPILE-ERROR: E2118

// `type_of` reads a value's type; handed a type it is refused, pointing at `type_info`.

import core.rtti

type Point = struct {
    x: i32
}

pub fn main() i32 {
    #if type_of(Point).copyable {
        return 1
    }
    return 0
}
