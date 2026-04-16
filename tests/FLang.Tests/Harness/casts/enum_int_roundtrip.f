//! TEST: enum_int_roundtrip
//! EXIT: 0
//! STDOUT: 1 Green red

// Bare enum tag values are 0, 1, 2... in declaration order.
// `i32 as Enum` constructs a variant from a tag; `e as i32` extracts it.
// The round-trip is used by FFI shims that share numeric error codes with C.

type Color = enum {
    Red
    Green
    Blue
}

fn name(c: Color) String {
    c match {
        Red => "red",
        Green => "Green",
        Blue => "blue",
    }
}

pub fn main() i32 {
    const g: Color = 1i32 as Color
    const tag = g as i32
    print(tag)
    print(" ")
    print(name(g))
    print(" ")
    const r = 0i32 as Color
    println(name(r))
    return 0
}
