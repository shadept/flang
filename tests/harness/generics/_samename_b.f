//! TEST: generics_samename_helper_b
//! SKIP: helper module for generic_specialization_same_type_name — not run directly

import std.option

pub type Thing = struct { w: i64 }

pub fn make_b(x: i64) Thing? {
    if x > 0 { return Some(Thing { w = x }) }
    return null
}
