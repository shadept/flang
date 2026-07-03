//! TEST: instantiation_note
//! COMPILE-ERROR: E2001

fn do_thing(val: $T) i32 {
    return val.nonexistent_method()
}

// do_thing(42) with unsuffixed 42 → E2001 (cannot determine concrete type)
// because there is no context to constrain the type variable.
// Use do_thing(42i32) to get E2004 instead.
pub fn main() i32 {
    return do_thing(42)
}
