//! TEST: enum_bare_equality
//! EXIT: 0
//! STDOUT: k==Green
//! STDOUT: k!=Red
//! STDOUT: k!=m

// Bare enums (no variant payloads) get built-in `==` / `!=` compiled down to
// a tag compare — no user-defined `op_eq` required. Ordering operators still
// error (see `error_e2017_bare_enum_no_ordering.f`), and tagged enums still
// require a user-defined `op_eq` (see `error_e2017_tagged_enum_no_eq.f`).

type Color = enum {
    Red
    Green
    Blue
}

pub fn main() i32 {
    let k: Color = Color.Green
    let m: Color = Color.Red

    if k == Color.Green { println("k==Green") } else { println("FAIL: k not Green") }
    if k != Color.Red   { println("k!=Red") } else { println("FAIL: k == Red") }
    if k != m           { println("k!=m") }    else { println("FAIL: k == m") }

    return 0
}
