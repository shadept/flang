//! TEST: where_copyable_through_generic
//! COMPILE-ERROR: E2134 where_copyable_through_generic.f
//! EXIT: 1

type FileHandle = struct {
    owned fd: i32
}

fn open(n: i32) FileHandle {
    return .{ fd = n }
}

fn twice(x: $T) T where T: copyable {
    let a = x
    return a
}

fn outer(x: move $U) U {
    return twice(x)
}

// A bound unsatisfied inside another generic body is reported at the call that chose `U`.
pub fn main() i32 {
    const h = outer(open(3))       // error E2134
    return 0
}
