//! TEST: lambda_brace_block
//! EXIT: 42

// RFC-039: outside argument position a `{` is a block unless `=>`, `ident =>`, `ident ,` or `ident
// :` follows it; an uppercase name before `{` constructs, a lowercase one takes a lambda.

type Point = struct {
    x: i32
    y: i32
}

fn make() fn(i32) i32 {
    return { x: i32 => x + 1 }
}

pub fn main() i32 {
    const p = Point { x = 20, y = 1 }
    const b: i32 = {
        const t: i32 = p.x
        t + p.y
    }
    const f: fn(i32) i32 = make()
    const g = { a: i32, c: i32 => a - c }
    return f(b) + g(25, 5)
}
