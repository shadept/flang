//! TEST: iterator_custom_fibonacci
//! EXIT: 20

struct Fibonacci {
    a: u64
    b: u64
    max: u64
}

fn iter(fib: &Fibonacci) Fibonacci {
    return .{ a = fib.a, b = fib.b, max = fib.max }
}

fn next(fib: &Fibonacci) u64? {
    if (fib.a > fib.max) {
        return null
    }
    let result = fib.a
    let tmp = fib.a + fib.b
    fib.a = fib.b
    fib.b = tmp
    return result
}

pub fn main() i32 {
    let f: Fibonacci = .{ a = 1, b = 1, max = 10 }
    let sum: u64 = 0
    for (x in f) {
        sum = sum + x
    }
    return sum as i32  // 1 + 1 + 2 + 3 + 5 + 8 = 20
}
