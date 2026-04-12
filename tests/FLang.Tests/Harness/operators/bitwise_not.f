//! TEST: bitwise_not
//! EXIT: 0

// Bitwise NOT operator (~) on integer types

pub fn main() i32 {
    // u8
    let a: u8 = 0
    let b: u8 = ~a
    if (b != 255) { return 1 }

    let c: u8 = 0xFF
    let d: u8 = ~c
    if (d != 0) { return 2 }

    // i32
    let e: i32 = 0
    let f: i32 = ~e
    if (f != -1) { return 3 }

    // usize
    let g: usize = 0xFF00
    let h: usize = ~g
    // Check low bits are set
    if (h & 0xFF != 0xFF) { return 4 }

    // Double complement is identity
    let i: i32 = 42
    if (~~i != 42) { return 5 }

    // Compose with XOR: ~x == x ^ (-1) for signed
    let j: i32 = 123
    if (~j != j ^ -1) { return 6 }

    return 0
}
