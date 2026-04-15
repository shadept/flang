//! TEST: error_e1006_break_outside_loop
//! COMPILE-ERROR: E1006

// Break outside loop is caught during parsing (E1006).
// E3006 is still emitted by lowering as a safety net.
pub fn main() i32 {
    break  // ERROR: `break` statement outside of loop
    return 0
}
