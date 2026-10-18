//! TEST: lambda_trailing_slot
//! EXIT: 42

// RFC-039: a trailing lambda fills the last callable parameter, past defaulted ones before it, with
// defaulted ones after it, beside named arguments and other callables.

fn stepped(x: i32, step: i32 = 1, f: fn(i32) i32) i32 {
    return f(x + step)
}

fn scaled(x: i32, f: fn(i32) i32, scale: i32 = 2) i32 {
    return f(x) * scale
}

fn zero() i32 {
    return 0
}

fn both(f: fn() i32, g: fn() i32 = zero) i32 {
    return f() * 10 + g()
}

pub fn main() i32 {
    const a: i32 = stepped(1) { x: i32 => x * 2 }
    const b: i32 = scaled(3) { x: i32 => x + 1 }
    const c: i32 = scaled(x = 2) { x: i32 => x }
    const d: i32 = 1.scaled { x: i32 => x }
    const e: i32 = both({ => 1 }) { => 2 }
    return a + b + c + d + e + 12
}
