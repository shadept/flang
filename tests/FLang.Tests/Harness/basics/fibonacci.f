//! TEST: fibonacci_test
//! EXIT: 55

fn fibonacci(n: i32) i32 {
    if (n <= 1) {
        return n
    }
    return fibonacci(n - 1) + fibonacci(n - 2)
}

pub fn main() i32 {
    return fibonacci(10)
}
