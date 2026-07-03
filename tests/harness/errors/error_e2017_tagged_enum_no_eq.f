//! TEST: error_e2017_tagged_enum_no_eq
//! COMPILE-ERROR: E2017

// The built-in enum equality only applies to BARE enums — enums whose every
// variant carries no payload. Tagged unions like this one still need a
// user-defined `op_eq` (or `op_cmp`) because tag-alone comparison would
// silently ignore payload contents, giving `Foo.A(1) == Foo.A(2)`.

type Foo = enum {
    A(i32)
    B
}

pub fn main() i32 {
    const x = Foo.A(1)
    const y = Foo.A(2)
    if x == y { return 1 }
    return 0
}
