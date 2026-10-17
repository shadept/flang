//! TEST: context_field_type
//! COMPILE-ERROR: E2002
//! EXIT: 1

context level: i32 = 0

pub fn main() i32 {
    return context(level = "high") { context.level } // error E2002
}
