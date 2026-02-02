//! TEST: instantiation_note
//! COMPILE-ERROR: E2004

fn do_thing(val: $T) i32 {
    return val.nonexistent_method()
}

pub fn main() i32 {
    return do_thing(42)
}
