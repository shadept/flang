//! TEST: inline_address_of_param
//! EXIT: 54

// A non-pub single-block helper is inline-eligible. One that takes the
// address of its own parameter must NOT be inlined: the parameter is a
// by-value copy with no stand-in variable at the call site. Keeping the
// parameter's name emits C that references an undeclared identifier at
// the inline site (or accidentally captures a same-named caller local);
// substituting the caller's argument variable would alias - the write
// through `p` below would corrupt the caller's `x`.

fn bump(v: i32) i32 {
    let p = &v
    p.* = p.* + 1
    return p.*
}

fn run(x: i32) i32 {
    let r = bump(x)
    // r = 5 (the copy was bumped), x must still be 4.
    return r * 10 + x
}

pub fn main() i32 {
    return run(4)
}
