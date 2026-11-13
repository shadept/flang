//! TEST: labeled_lambda
//! NO-COMPILE-WARNING: W1005
//! EXIT: 6

// A lambda body is outside every enclosing loop, so a label inside it may reuse an outer name.
pub fn main() i32 {
    let total: i32 = 0
    outer: for i in 0..3 as i32 {
        const f = { n: i32 =>
            let s: i32 = 0
            outer: for k in 0..10 as i32 {
                if k == n {
                    break outer
                }
                s = s + 1
            }
            s
        }
        if i == 9 {
            break outer
        }
        total = total + f(i + 1)
    }
    return total
}
