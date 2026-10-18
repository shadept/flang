//! TEST: lambda_brace_arg
//! EXIT: 42

// RFC-039: `{ params => body }` in argument position and as an initializer.

fn apply(f: fn(i32) i32, x: i32) i32 {
    return f(x)
}

fn combine(a: i32, b: i32, f: fn(i32, i32) i32) i32 {
    return f(a, b)
}

pub fn main() i32 {
    const a: i32 = apply({ x: i32 => x * 2 }, 5)
    const b: i32 = combine(3, 4, { p, q => p * q })
    const inc: fn(i32) i32 = { x => x + 1 }
    const bump: fn() i32 = { => 9 }
    return a + b + inc(0) + bump() + 10
}
