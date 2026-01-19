//! TEST: error_e2007_continue_outside_loop
//! COMPILE-ERROR: E3007

// Note: Continue outside loop is currently caught during lowering (E3007) not
// during semantic analysis (E2007)
pub fn main() i32 {
    continue  // ERROR: `continue` statement outside of loop
    return 0
}
