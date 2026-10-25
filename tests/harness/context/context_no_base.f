//! TEST: context_no_base
//! COMPILE-ERROR: E2153
//! EXIT: 1

context level: i32 = 0

pub fn main() i32 {
    return context(1i32, level = 2i32) { context.level } // error E2153: a rebind has no base
}
