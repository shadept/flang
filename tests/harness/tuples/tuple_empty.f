//! TEST: tuple_empty
//! EXIT: 42

// Empty tuple () is the unit type

fn unit_fn() () {
    return ()
}

pub fn main() i32 {
    unit_fn()
    return 42
}
