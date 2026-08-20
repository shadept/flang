//! TEST: if_directive_or_and
//! EXIT: 0

// #if conditions follow FLang expression semantics: or / and / ! / parens.

pub fn main() i32 {
    let result: i32 = 1

    // One of these is true on every supported platform
    #if platform.os == "macos" or platform.os == "linux" or platform.os == "windows" {
        result = 0
    }

    // `and` with a negation: never taken (os can't be two things)
    #if platform.os == "macos" and platform.os == "linux" {
        result = 2
    }

    // `!` on a bool path: runtime.testing is false outside `flang test`
    #if !runtime.testing and true {
        // keep result as-is
    } else {
        result = 3
    }

    return result
}
