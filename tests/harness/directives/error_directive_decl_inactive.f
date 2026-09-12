//! TEST: directives_error_directive_decl_inactive
//! EXIT: 0

// A declaration-level `#error` in an inactive branch is dropped with the branch.

#if platform.os == "plan9" {
    #error("no plan9 support")
}

pub fn main() i32 {
    return 0
}
