//! TEST: defer_scope
//! EXIT: 15

// Test defer in nested scopes
// Each defer should execute at the end of its enclosing scope

pub fn main() i32 {
    let x: i32 = 0

    if (true) {
        defer x = x + 10
        x = 5
    }
    // After if block: defer executed, x should be 5 + 10 = 15

    return x
}
