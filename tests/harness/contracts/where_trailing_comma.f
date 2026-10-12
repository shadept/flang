//! TEST: where_trailing_comma
//! EXIT: 7

// A `where` list takes a trailing comma, on one line or broken one bound per line.
fn pick(a: $T, b: $U) T where T: copyable, U: copyable, {
    return a
}

fn apply(x: $T, f: $F) T
where
    T: copyable,
    F: fn(T) T,
{
    return f(x)
}

pub fn main() i32 {
    return pick(3i32, true) + apply(3i32, fn(v: i32) i32 { v + 1 })
}
