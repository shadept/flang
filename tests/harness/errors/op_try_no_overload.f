//! TEST: op_try_no_overload
//! COMPILE-ERROR: E2092
//! EXIT: 1

// `?` on a struct that has no op_try defined. We can't use a primitive like
// `42?` here because untyped integer literals coerce into `Option(?)` via the
// OptionWrappingCoercionRule before op_try resolution can flag the mismatch —
// E2092 is reachable when the operand has a fixed nominal type with no op_try.

type Plain = struct { x: i32 }

fn make() Plain { return Plain { x = 1 } }

fn caller() i32 {
    let p = make()
    let x = p?
    return x.x
}

pub fn main() i32 {
    return caller()
}
