//! TEST: char_literal
//! EXIT: 0
pub fn main() i32 {
    let a: char = 'A'
    if (a != 65u32 as char) { return 1 }

    let b: char = 'z'
    if (b != 122u32 as char) { return 2 }

    // Escape sequences
    let nl: char = '\n'
    if (nl != 10u32 as char) { return 3 }

    let tab: char = '\t'
    if (tab != 9u32 as char) { return 4 }

    let nul: char = '\0'
    if (nul != 0u32 as char) { return 5 }

    return 0
}
