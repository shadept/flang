//! TEST: generics_samename_helper_a
//! SKIP: helper module for generic_specialization_same_type_name - not run directly

import std.option

pub type Thing = struct { v: i32 }

pub fn make_a(x: i32) Thing? {
    if x > 0 { return Some(Thing { v = x }) }
    return null
}
