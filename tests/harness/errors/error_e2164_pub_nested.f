//! TEST: error_e2164_pub_nested
//! COMPILE-ERROR: E2164

// RFC-046: `pub` is valid on a module-level type and on a type nested in a `pub` type only.
type Private = struct {
    pub type Inner = i32 // error[E2164]
    i: Inner
}

pub fn main() i32 {
    pub type InFn = i32 // error[E2164]
    const p: Private = Private { i = 1 }
    const x: InFn = 2
    return p.i + x
}
