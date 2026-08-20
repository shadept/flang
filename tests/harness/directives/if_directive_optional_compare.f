//! TEST: if_directive_optional_compare
//! COMPILE-ERROR: E2118

// runtime.env indexing yields an optional (FLang Dict semantics);
// comparing it without `??` is an error.

pub fn main() i32 {
    #if runtime.env["MODE"] == "release" {
        return 1
    }
    return 0
}
