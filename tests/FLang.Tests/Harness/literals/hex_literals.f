//! TEST: hex_literals
//! EXIT: 0
pub fn main() i32 {
    // Basic hex literals with type annotation
    let a: i32 = 0xff
    let b: i32 = 0xFF
    let c: i32 = 0x10

    // Hex with type suffixes
    let d = 0xffu8
    let e = 0xDEADi32

    // Verify values
    if (a != 255i32) { return 1 }
    if (b != 255i32) { return 2 }
    if (c != 16i32) { return 3 }
    if (d != 255u8) { return 4 }
    if (e != 57005i32) { return 5 }

    return 0
}
