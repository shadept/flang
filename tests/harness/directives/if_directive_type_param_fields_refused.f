//! TEST: if_directive_type_param_fields_refused
//! COMPILE-ERROR: E2120

// A type parameter's `type_info(T)` in `#if` carries name, kind and copyable only; the syntax-derived
// members are refused rather than read as empty.

import core.rtti

fn probe(x: &$T) i32 {
    #if type_info(T).fields.len == 0 {
        return 1
    }
    return 0
}

pub fn main() i32 {
    let n: i32 = 0
    return probe(&n)
}
