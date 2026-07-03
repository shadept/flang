//! TEST: op_try_option_cross_T
//! EXIT: 0

// `?` on `Option(T)` must work inside any function returning `Option(U)`
// for any `U` — `None` is shape-only. The Return slot's type variable
// is bound from the enclosing function's return type via inference, no
// per-call wrapping needed.

import std.option

fn first_nonzero(xs: i32[]) i32? {
    for x in xs { if x != 0 { return Some(x) } }
    return None
}

// Caller returns Option of a TUPLE — different `T` from the source.
fn first_nonzero_doubled(xs: i32[]) (i32, i32)? {
    let v = first_nonzero(xs)?
    return Some((v, v * 2))
}

pub fn main() i32 {
    let xs: i32[] = [0, 0, 7, 1]
    let r = first_nonzero_doubled(xs)
    let p = r match {
        Some(t) => t,
        None => return 1,
    }
    if p.0 != 7 { return 2 }
    if p.1 != 14 { return 3 }

    let zeros: i32[] = [0, 0, 0]
    let none_r = first_nonzero_doubled(zeros)
    if none_r.is_some() { return 4 }

    return 0
}
