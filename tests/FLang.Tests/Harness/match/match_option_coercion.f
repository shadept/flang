//! TEST: match_option_coercion
//! EXIT: 1

import std.option

type Color = enum { Red, Green, Blue }

fn get_value(c: Color) i32? {
    return c match {
        Red => 1,
        Green => 2,
        else => null
    }
}

pub fn main() i32 {
    let v = get_value(Color.Red)
    return v ?? 0
}
