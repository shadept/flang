//! TEST: context_base_first
//! COMPILE-ERROR: E2153
//! EXIT: 1

context level: i32 = 0

pub fn main() i32 {
    const saved: Context = context
    return context(level = 1i32, saved) { context.level } // error E2153: the base comes first
}
