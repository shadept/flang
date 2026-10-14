//! TEST: literal_to_enum
//! EXIT: 0
//! STDOUT: 2 12 27

import std.io.print

// An unsuffixed literal cast to a bare enum takes the enum's i32 discriminant type, as `27 as u8`
// takes u8: `12 as Month` reads as `12i32 as Month`.

type Month = enum {
    January = 1
    February = 2
    December = 12
}

pub fn main() i32 {
    const f: Month = 2 as Month
    print(f as i32)
    print(" ")
    print((12 as Month) as i32)
    print(" ")
    const b: u8 = 27 as u8
    println(b)
    return 0
}
