//! TEST: error_e1007_continue_outside_loop
//! COMPILE-ERROR: E1007

// Continue outside loop is caught during parsing (E1007).
// E3007 is still emitted by lowering as a safety net.
pub fn main() i32 {
    continue  // ERROR: `continue` statement outside of loop
    return 0
}
