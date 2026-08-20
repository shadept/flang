//! TEST: if_directive_unknown_member
//! COMPILE-ERROR: E2116

// A typo'd member on a valid root must be a hard error.

pub fn main() i32 {
    #if platform.oss == "windows" {
        return 1
    }
    return 0
}
