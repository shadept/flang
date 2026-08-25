//! TEST: condition_is_expression
//! EXIT: 0

// An `if` / `while` condition, and a `for` iterable, is an ordinary
// expression: keyword, expression, block. The only thing special about it is
// that the body's `{` terminates the expression - and that applies at the
// condition's own nesting level only. Inside `(...)`, `[...]` or `{...}` a
// brace cannot be the body brace, because the delimiter has to close first.

pub type P = struct { x: i32 }

fn take(p: P) i32 {
    return p.x
}

pub fn main() i32 {
    let a: i32 = 1
    let b: i32 = 2
    let n: i32 = 0

    // A leading group is grouping, not a condition wrapper: the expression
    // continues past its `)`.
    if (a + b) * 4 > 6 {
        n = n + 1
    }

    while (a + 1) * 2 > 3 {
        a = a - 1
    }

    // A struct literal inside a group.
    if (P { x = 1 }).x > 0 {
        n = n + 1
    }

    // A struct literal inside call arguments.
    if take(P { x = 1 }) > 0 {
        n = n + 1
    }

    // A struct literal inside an index expression.
    let xs: i32[] = [10, 20]
    if xs[take(P { x = 1 }) as usize] > 15 {
        n = n + 1
    }

    // A `for` iterable is parsed the same way.
    for i in 0..(b + 1) - 2 {
        n = n + 1
    }

    // The body brace is still the body: a bare identifier iterable does not
    // swallow it as a struct literal.
    for v in xs {
        n = n + v
    }

    // A match expression in a condition: its arms are brace-delimited too.
    if b match { 2 => true, _ => false } {
        n = n + 1
    }

    // A wrapped condition is just a grouped expression.
    if (n > 0) {
        n = n + 1
    }

    // n: five single increments, then + 10 + 20 from the loop over xs,
    // then the match and the wrapped condition: 37.
    // a: 1 -> 0 after one while iteration.
    return (n - 37) + a
}
