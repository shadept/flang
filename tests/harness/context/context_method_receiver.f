//! TEST: context_method_receiver
//! COMPILE-ERROR: E2149
//! EXIT: 1

context level: i32 = 0

fn level_of(c: &Context) i32 {
    return c.level
}

pub fn main() i32 {
    return context.level_of()                            // error E2149: only a field is called
}
