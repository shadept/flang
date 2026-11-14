//! TEST: foreign_union
//! STDOUT: PASS

// A `#foreign union` overlaps its members at offset 0, is sized like C's union, and crosses a C
// call by value as a real C `union`: a float-only union is SSE class on SysV, where a byte blob
// would have travelled in integer registers.

import std.io.print

import _foreign_shim

pub type Bits = #foreign union {
    word: u32
    bytes: [u8; 4]
    wide: u64
    odd: [u8; 9]
}

pub fn main() i32 {
    if size_of(Bits) != 16 or align_of(Bits) != 8 {
        println("FAIL: layout")
        return 1
    }
    let b = Bits { word = 0x01020304u32 }
    if b.bytes[0] != 4u8 and b.bytes[0] != 1u8 {
        println("FAIL: members do not overlap")
        return 1
    }
    b.bytes[0] = 0xFFu8
    if b.word == 0x01020304u32 {
        println("FAIL: write through one member not seen by another")
        return 1
    }
    if type_info(Bits).kind != TypeKind.Union {
        println("FAIL: rtti kind")
        return 1
    }
    const r = shim_twice(Num { d = 1.25 })
    if r.d != 2.5 {
        println("FAIL: by-value round trip")
        return 1
    }
    println("PASS")
    return 0
}
