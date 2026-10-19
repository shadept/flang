//! TEST: fn_call_through_place
//! EXIT: 0

// A call through any expression of function type calls its value: an element, a dereference, a
// call's result, a branch (RFC-037).

fn inc(x: i32) i32 {
    return x + 1
}

fn dbl(x: i32) i32 {
    return x * 2
}

fn pick(double: bool) fn(i32) i32 {
    return if double { dbl } else { inc }
}

pub fn main() i32 {
    let hs: [fn(i32) i32; 2] = [inc, dbl]
    const p: &fn(i32) i32 = &hs[1]
    const by_index: i32 = hs[0](5)
    const by_deref: i32 = p.*(5)
    const by_call: i32 = pick(true)(5)
    const by_branch: i32 = (if by_index > 5 { inc } else { dbl })(5)
    return by_index + by_deref + by_call + by_branch - 32
}
