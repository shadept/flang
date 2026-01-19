//! TEST: error_e2006_break_outside_loop
//! COMPILE-ERROR: E3006

// Note: Break outside loop is currently caught during lowering (E3006) not
// during semantic analysis (E2006)
pub fn main() i32 {
    break  // ERROR: `break` statement outside of loop
    return 0
}
