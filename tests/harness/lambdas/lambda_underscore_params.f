//! TEST: lambda_underscore_params
//! EXIT: 0

// `_` names a lambda parameter the body never reads, in any position, as often as needed, typed or
// not.

fn apply3(f: fn(i32, i32, i32) i32) i32 {
    return f(1, 2, 3)
}

fn apply2(f: fn(i32, i32) i32) i32 {
    return f(10, 20)
}

pub fn main() i32 {
    const all: i32 = apply3 { _, _, _ => 7 }
    const last: i32 = apply2 { _, y => y }
    const typed: i32 = apply2 { x: i32, _: i32 => x }
    return all + last + typed - 37
}
