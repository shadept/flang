//! TEST: labeled_unknown
//! COMPILE-ERROR: E1055 no enclosing loop is labeled `outr`; labels in scope: `inner`, `outer`
//! COMPILE-ERROR: E1055 no enclosing loop is labeled `outer`
//! EXIT: 1

// A label resolves only against the loops enclosing the jump, and a lambda body encloses none of
// the loops outside it.
pub fn main() i32 {
    outer: for i in 0..3 as i32 {
        inner: for j in 0..3 as i32 {
            if j == i {
                break outr
            }
            continue inner
        }
        const f = { n: i32 =>
            loop {
                break outer
            }
            n
        }
        if f(i) == 2 {
            break outer
        }
    }
    return 0
}
