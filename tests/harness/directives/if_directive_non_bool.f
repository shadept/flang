//! TEST: if_directive_non_bool
//! COMPILE-ERROR: E2117

// `if platform.os {}` is not valid FLang, so it is not a valid #if:
// conditions must evaluate to bool — a string is an error.

pub fn main() i32 {
    #if platform.os {
        return 1
    }
    return 0
}
