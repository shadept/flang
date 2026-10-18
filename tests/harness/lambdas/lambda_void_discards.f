//! TEST: lambda_void_discards
//! EXIT: 42

// RFC-039: a lambda filling a callable that returns nothing discards its body's last value, through
// a function type and through a bound; its parameters take the expected types.

fn each(n: i32, f: fn(i32)) {
    for i in 0..n {
        f(i)
    }
}

fn visit(n: i32, f: $F) where F: fn(i32) {
    for i in 0..n {
        f(i)
    }
}

fn bump(total: &i32, by: i32) i32 {
    total.* = total.* + by
    return total.*
}

fn doubled(x: i32) i32 {
    return x * 2
}

pub fn main() i32 {
    each(2) { doubled(it) }
    let total: i32 = 0
    visit(4) { i => bump(&total, i) }
    visit(3) { bump(&total, it * 10) }
    return total + 6
}
