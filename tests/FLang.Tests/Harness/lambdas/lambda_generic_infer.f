//! TEST: lambda_generic_infer
//! EXIT: 42

// Test lambda parameter type inference via TypeVars + UFCS resolution.
// fn(x) { x.double() } — x has no type annotation and no expected type context.
// UFCS resolves x.double() → double(x), binding TypeVar_x to i32.

fn double(x: i32) i32 {
    return x * 2
}

fn apply(f: fn($T) $U, x: $T) $U {
    return f(x)
}

pub fn main() i32 {
    return apply(fn(x) { x.double() }, 21)
}
