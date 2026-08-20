//! TEST: if_directive_env
//! EXIT: 0

// runtime.env follows FLang Dict semantics: indexing yields an optional
// that must be unwrapped with `??` before comparison.

pub fn main() i32 {
    let result: i32 = 1

    // Absent variable: `??` supplies the fallback
    #if (runtime.env["FLANG_TEST_SURELY_UNSET_XYZ"] ?? "fallback") == "fallback" {
        result = 0
    }

    // PATH is set in any sane environment; ?? keeps the real value
    #if (runtime.env["PATH"] ?? "") != "" {
        // keep result
    } else {
        result = 2
    }

    return result
}
