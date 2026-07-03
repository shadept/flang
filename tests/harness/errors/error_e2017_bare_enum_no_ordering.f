//! TEST: error_e2017_bare_enum_no_ordering
//! COMPILE-ERROR: E2017

// Bare enums get `==`/`!=` built-in, but not `<`/`>`/`<=`/`>=`: tag values
// aren't a meaningful total order without the author's intent. Users who do
// want ordering can define `op_cmp(Color, Color)` themselves.

type Color = enum {
    Red
    Green
    Blue
}

pub fn main() i32 {
    let a: Color = Color.Red
    let b: Color = Color.Green
    if a < b { return 1 }
    return 0
}
