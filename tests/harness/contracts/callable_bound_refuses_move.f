//! TEST: callable_bound_refuses_move
//! COMPILE-ERROR: E2134
//! EXIT: 1

type Handle = struct {
    fd: i32
}

fn apply(x: &$T, f: $F) i32 where F: fn(T) i32 {
    return 0
}

fn take(h: move Handle) i32 {
    return h.fd
}

pub fn main() i32 {
    const h = Handle { fd = 3 }
    // A callable that would own the argument, where the bound keeps it with the caller.
    return apply(&h, take) // error E2134
}
