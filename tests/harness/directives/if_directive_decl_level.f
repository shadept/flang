//! TEST: if_directive_decl_level
//! EXIT: 0

// Declaration-level #if: only the active branch's declarations are
// collected. Both branches must parse; the inactive branch may declare
// the same names without conflict.

#if runtime.testing {
    const ANSWER: i32 = 99

    type Marker = struct {
        value: i32,
    }

    fn describe() i32 {
        return 1
    }
} else {
    const ANSWER: i32 = 42

    type Marker = struct {
        value: i32,
    }

    fn describe() i32 {
        return 0
    }

    // Nested decl-level #if inside a branch
    #if platform.os == "macos" or platform.os == "linux" or platform.os == "windows" {
        fn nested_ok() bool {
            return true
        }
    }
}

pub fn main() i32 {
    const m = Marker { value = describe() }
    if !nested_ok() { return 3 }
    if m.value != 0 { return 1 }
    return 0
}
