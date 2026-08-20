//! TEST: if_directive_decl_error
//! COMPILE-ERROR: E2116

// Decl-level #if conditions get the same strict validation as
// statement-level ones (evaluated at flatten time, before collection).

#if platfrom.os == "windows" {
    fn windows_only() i32 {
        return 1
    }
}

pub fn main() i32 {
    return 0
}
