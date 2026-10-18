//! TEST: lambda_it
//! EXIT: 42

// RFC-039: a lambda without `=>` takes its arity from the callable it fills - one parameter named
// `it`, or none, where an outer `it` stays visible.

fn apply(f: fn(i32) i32, x: i32) i32 {
    return f(x)
}

fn bounded(x: i32, f: $F) i32 where F: fn(i32) i32 {
    return f(x)
}

fn run(f: $F) i32 where F: fn() i32 {
    return f()
}

pub fn main() i32 {
    const it: i32 = 10
    const a: i32 = apply({ it * 2 }, 3)
    const b: i32 = bounded(4) { it + 1 }
    const c: i32 = run { it }
    const d: i32 = bounded(5) { bounded(it) { it * 2 } }
    return a + b + c + d + 11
}
