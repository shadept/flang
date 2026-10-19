//! TEST: foreign_fn_call_through_place
//! EXIT: 0

// A call through an element or a dereference of `#foreign fn` type is a plain C call (RFC-037).

#foreign fn abs(x: i32) i32

#foreign fn negate(x: i32) i32 {
    return -x
}

pub fn main() i32 {
    let cs: [#foreign fn(i32) i32; 2] = [abs, negate]
    const p: &#foreign fn(i32) i32 = &cs[1]
    return cs[0](-3i32) + p.*(3i32)
}
