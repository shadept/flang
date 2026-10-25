//! TEST: context_leak_refused
//! COMPILE-ERROR: E2149
//! EXIT: 1

// A copy of a rebind's context would carry `&s` past the frame that owns it.

type Svc = struct {
    n: i32
}

context svc: &Svc? = null

fn leak() i32 {
    let s = Svc { n = 42i32 }
    const c = context(svc = Some(&s)) { context }        // error E2149: not a value
    return 0
}

pub fn main() i32 {
    return leak()
}
