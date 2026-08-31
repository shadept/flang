//! TEST: leading_operator_continues_statement
//! EXIT: 16

// No statement terminator, so a line opening with a token that can continue the
// expression before it does exactly that. Neither pair below is two statements:
// `a` binds `one() - 3`, which is -2, and `b` binds `take(4)`, which is 4. The
// result is 2 + 4 + 10, and nothing in the source looks wrong.

fn one() i32 {
    return 1
}

fn take(v: i32) i32 {
    return v
}

pub fn main() i32 {
    let a = one()
    -3
    let b = take
    (4)
    return a * -1 + b + 10
}
