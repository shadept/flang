//! TEST: if_directive_unknown_root
//! COMPILE-ERROR: E2116

// A typo'd compile-time root must be a hard error, never silently false.

pub fn main() i32 {
    #if plataform.os == "windows" {
        return 1
    }
    return 0
}
