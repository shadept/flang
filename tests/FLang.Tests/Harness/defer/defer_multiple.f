//! TEST: defer_multiple
//! EXIT: 3

// Test multiple defer statements - should execute in LIFO order (reverse)
// Inside block: x = 0
// defer x = x + 1  (executes third/last, x becomes 2 + 1 = 3)
// defer x = x + 1  (executes second, x becomes 1 + 1 = 2)
// defer x = x + 1  (executes first, x becomes 0 + 1 = 1)

pub fn main() i32 {
    let x: i32 = 0

    {
        defer x = x + 1
        defer x = x + 1
        defer x = x + 1
    }
    // LIFO: last defer executes first
    // x = 0 + 1 = 1, then x = 1 + 1 = 2, then x = 2 + 1 = 3

    return x
}
