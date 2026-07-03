//! TEST: underscore_separators
//! EXIT: 0
pub fn main() i32 {
    // Decimal with underscores
    let a: i32 = 1_000_000
    let b: i32 = 1_2_3_4

    // Hex with underscores
    let c: i32 = 0xff_ff
    let d: u64 = 0xDEAD_BEEF

    // With type suffixes
    let e = 1_000i32
    let f = 0xff_ffu32

    // Verify values
    if (a != 1000000i32) { return 1 }
    if (b != 1234i32) { return 2 }
    if (c != 65535i32) { return 3 }
    if (d != 3735928559u64) { return 4 }
    if (e != 1000i32) { return 5 }
    if (f != 65535u32) { return 6 }

    return 0
}
