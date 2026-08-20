//! TEST: address_of_param
//! EXIT: 54

// Taking the address of a function parameter is a basic language
// feature: the parameter is an ordinary local (a by-value copy), so
// `&param` yields a pointer to that copy. Reads see the argument's
// value; writes mutate only the copy, never the caller's variable.
// Must hold through every pipeline configuration (the helper below is
// small and non-pub, so it is also inline-eligible).

fn read_it(v: i32) i32 {
    let p = &v
    return p.*
}

fn bump(v: i32) i32 {
    let p = &v
    p.* = p.* + 1
    return p.*
}

pub fn main() i32 {
    let x = 4
    if read_it(x) != 4 { return 1 }
    let r = bump(x)
    // r saw the bumped copy; x is untouched.
    return r * 10 + x
}
