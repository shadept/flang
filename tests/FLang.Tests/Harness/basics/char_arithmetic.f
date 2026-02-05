//! TEST: char_arithmetic
//! EXIT: 0
// char participates in integer operations (it's a u32 alias)
pub fn main() i32 {
    let a: char = 'A'
    let offset: char = 32u32 as char
    let lower: char = a + offset   // 'a' = 65 + 32 = 97
    if (lower != 97u32 as char) { return 1 }

    // Bitwise operations work on char
    let x: char = '\u0FF0'
    let masked: char = x & '\u00FF'
    if (masked != '\u00F0') { return 2 }

    // Shift operations work on char
    let y: char = 1u32 as char
    let shifted: char = y << 8u32 as char
    if (shifted != 256u32 as char) { return 3 }

    return 0
}
