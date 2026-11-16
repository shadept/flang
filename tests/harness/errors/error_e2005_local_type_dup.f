//! TEST: error_e2005_local_type_dup
//! COMPILE-ERROR: E2005

// RFC-046: two declarations of one name in the same block scope.
pub fn main() i32 {
    type Event = struct { a: i32 }
    type Event = enum { A } // error[E2005]
    return 0
}
