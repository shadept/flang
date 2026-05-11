//! TEST: error_e2112_closure_assigns_capture
//! COMPILE-ERROR: E2112

// Captures are by value. An assignment to a captured name from inside the
// closure body cannot affect the outer scope — flagging it avoids the
// misleading "looks like outer mutation, isn't" surprise.

pub fn main() i32 {
    let k = 5
    let f = fn() i32 {
        k = 10
        return k
    }
    return f()
}
