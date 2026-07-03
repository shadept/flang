//! TEST: byte_literal
//! EXIT: 0
pub fn main() i32 {
    let a: u8 = b'A'
    if (a != 65u8) { return 1 }

    let b: u8 = b'0'
    if (b != 48u8) { return 2 }

    // Escape sequences in byte literals
    let nl: u8 = b'\n'
    if (nl != 10u8) { return 3 }

    let nul: u8 = b'\0'
    if (nul != 0u8) { return 4 }

    let backslash: u8 = b'\\'
    if (backslash != 92u8) { return 5 }

    return 0
}
