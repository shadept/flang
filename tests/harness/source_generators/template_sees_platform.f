//! TEST: template_sees_platform
//! EXIT: 0

// A template `#if` evaluates against the same closed compile-time context
// (`platform.*`, `runtime.*`) the `#if` directive uses, at expansion time —
// so both sides below agree on every target.

#define(make_os_check, Name: Ident) {
    #if platform.os == "windows" {
        fn #(Name)() bool { return true }
    } #else {
        fn #(Name)() bool { return false }
    }
}

#make_os_check(is_windows)

pub fn main() i32 {
    let expected: bool = false
    #if platform.os == "windows" {
        expected = true
    }
    if is_windows() == expected { return 0 }
    return 1
}
