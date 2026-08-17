//! TEST: generic_specialization_same_type_name
//! EXIT: 7

// Two modules each declare a `Thing`. Instantiating the same generic
// (`Option`) over both must produce two distinct specializations of
// `unwrap`. Keying specializations by the type's SHORT name made them
// collide: the second call site reused the function specialized over the
// first module's `Thing`, and since IR struct names are FQN-derived the
// emitted call named a symbol nothing defined - reported as E3002 against
// an unrelated file, far from the cause.

import std.option
import _samename_a
import _samename_b

pub fn main() i32 {
    let p = make_a(3)
    let q = make_b(4)
    if p.is_none() { return 1 }
    if q.is_none() { return 2 }
    return p.unwrap().v + (q.unwrap().w as i32)
}
