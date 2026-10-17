//! TEST: context_named_twice
//! COMPILE-ERROR: E2151
//! EXIT: 1

context level: i32 = 0

pub fn main() i32 {
    return context(level = 1i32, level = 2i32) { context.level } // error E2151
}
