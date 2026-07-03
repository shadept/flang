//! TEST: shift_unsigned
//! EXIT: 0
// >>> is logical shift: zero-fills from the left
pub fn main() i32 {
    // For unsigned types, >>> and >> behave identically
    let a: u32 = 40u32
    let b: u32 = a >>> 3u32
    if (b != 5u32) { return 1 }

    // For signed types, >>> zero-fills (logical shift)
    // -1 in i32 is 0xFFFFFFFF. >>> 16 should give 0x0000FFFF = 65535
    let c: i32 = -1
    let d: i32 = c >>> 16
    if (d != 65535) { return 2 }

    return 0
}
