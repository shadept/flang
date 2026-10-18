//! TEST: coalesce_no_op_try
//! COMPILE-ERROR: E2092
//! EXIT: 1

// `??` needs an `op_try` for its left side; a plain struct has none.

type Plain = struct { x: i32 }

pub fn main() i32 {
    let p: Plain = Plain { x = 1 }
    let q: Plain = p ?? Plain { x = 2 }
    return q.x
}
