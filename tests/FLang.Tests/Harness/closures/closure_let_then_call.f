//! TEST: closure_let_then_call
//! EXIT: 100

// Closure stored in a `let`, then invoked through that name. The literal's
// anonymous type travels by value; its op_call dispatches normally.

pub fn main() i32 {
    let scale = 25
    let quad = fn(x: i32) i32 { x * scale }
    let a = quad(2)
    let b = quad(2)
    return a + b
}
