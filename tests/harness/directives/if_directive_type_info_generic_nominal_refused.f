//! TEST: if_directive_type_info_generic_nominal_refused
//! COMPILE-ERROR: E2116

// A bare generic nominal carries no type arguments, so it is not a compile-time name in `#if`.

import core.rtti

type Box = struct(T) {
    value: T
}

pub fn main() i32 {
    #if type_info(Box).copyable {
        return 1
    }
    return 0
}
