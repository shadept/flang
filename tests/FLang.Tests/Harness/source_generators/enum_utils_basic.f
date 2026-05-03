//! TEST: enum_utils_basic
//! EXIT: 0

import std.enum
import std.option

type Color = enum {
    Red
    Green
    Blue
}

#enum_utils(Color)

pub fn main() i32 {
    // to_string
    if Color.Red.to_string() != "Red" { return 1 }
    if Color.Green.to_string() != "Green" { return 2 }
    if Color.Blue.to_string() != "Blue" { return 3 }

    // from_string
    let r = from_string("Red")
    if r.is_none() { return 4 }

    let g = from_string("Green")
    if g.is_none() { return 5 }

    let bad = from_string("Yellow")
    if bad.is_some() { return 6 }

    return 0
}
