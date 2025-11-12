//! TEST: defer_basic
//! EXIT: 10

// Test basic defer - should execute on scope exit
// Use a nested block to test defer execution

pub fn main() i32 {
    let x: i32 = 0

    {
        defer x = 10
        x = 5
    }
    // After block: defer executed, x should be 10

    return x
}
