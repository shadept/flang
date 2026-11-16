//! TEST: error_e2003_local_type_outside
//! COMPILE-ERROR: E2003

// RFC-046: a block-scoped type is not visible outside its block or in another function.
fn other() i32 {
    const e: Event = Event { a = 1 } // error[E2003]
    return e.a
}

pub fn main() i32 {
    {
        type Event = struct { a: i32 }
    }
    const e: Event = Event { a = 1 } // error[E2003]
    return e.a + other()
}
