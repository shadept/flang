//! TEST: closure_struct_returned
//! COMPILE-ERROR: E2011

// A closure's nominal has no spelling, so a struct wrapping one can only be
// named in a signature where a parameter binds the type variable. A function
// that builds the closure itself has nothing to bind `F`, so the return type
// is unwritable and the field never resolves to a callable.

type Adder = struct(F) {
    f: F,
}

fn make_adder(base: i32) Adder($F) {
    return .{ f = fn(x: i32) i32 { base + x } }
}

pub fn main() i32 {
    let a = make_adder(50i32)
    return a.f(5i32)
}
