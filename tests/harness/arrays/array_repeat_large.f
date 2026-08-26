//! TEST: array_repeat_large
//! EXIT: 0

// Non-zero repeat literals lower as a fill loop, so the count is not
// capped: constant fills past 64 elements, runtime fill values,
// non-byte element widths, and aggregate element values all materialize
// every element. Byte elements fill with one memset; the zero form is
// one memset at any width.

type Pair = struct {
    a: u8
    b: u64
}

fn runtime_fill(fill: u8) u64 {
    let buf: [u8; 4096] = [fill; 4096]
    let s: u64 = 0
    for i in 0..4096 {
        s = s + buf[i] as u64
    }
    return s
}

pub fn main() i32 {
    let big: [u8; 100] = [7; 100]
    let s: i32 = 0
    for i in 0..100 {
        s = s + big[i] as i32
    }
    if s != 700 {
        return 1
    }

    let zeros: [u8; 65] = [0; 65]
    if zeros[64] != 0 {
        return 2
    }

    if runtime_fill(3) != 12288 {
        return 3
    }

    let wide: [u64; 80] = [5; 80]
    if wide[0] != 5 or wide[79] != 5 {
        return 4
    }

    let pairs: [Pair; 70] = [Pair { a = 1, b = 9 }; 70]
    if pairs[0].a != 1 or pairs[69].b != 9 {
        return 5
    }

    return 0
}
