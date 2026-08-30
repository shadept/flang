//! TEST: allow_ref_to_int
//! EXIT: 42
//! NO-COMPILE-WARNING: W2004

// `#allow(CODE)` on a declaration silences that code for everything inside it. `read_addr` reads an
// address as an integer, which is legitimate and warns by default (RFC-026).

#allow(W2004)
fn read_addr(p: &i32) usize {
    return p as usize
}

pub fn main() i32 {
    let x: i32 = 42
    if read_addr(&x) == 0 {
        return 1
    }
    return x
}
