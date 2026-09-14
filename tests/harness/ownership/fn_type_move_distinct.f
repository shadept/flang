//! TEST: fn_type_move_distinct
//! COMPILE-ERROR: E2002 differ in `move`
//! EXIT: 1

fn read(v: i32) i32 {
    return v
}

fn peek(v: move i32) i32 {
    return v
}

// The parameter carries the decision: `fn(i32)` and `fn(move i32)` are distinct types. `read` is
// overloaded, `peek` is not; both resolve against the slot's type.
pub fn main() i32 {
    let f: fn(move i32) i32 = read // error: type mismatch
    let g: fn(i32) i32 = peek      // error: type mismatch
    return f(3) + g(3)
}
