//! TEST: ptr_usize_roundtrip
//! COMPILE-ERROR: E2122
//! COMPILE-WARNING: W2004

// An address may leave the type system as an integer and never come back (RFC-026). The outbound
// cast warns; the return trip is refused, which is what keeps the escape analysis behind
// copy-on-write parameters sound.

pub fn main() i32 {
    let x: i32 = 42
    let p: &i32 = &x

    let addr: usize = p as usize
    let p2: &i32 = addr as &i32

    return p2.*
}
