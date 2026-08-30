//! TEST: null_ref_literal
//! EXIT: 7
//! NO-COMPILE-WARNING: E2122

// `0 as &T` is how a null reference is spelled while the language has no null primitive, so it is
// exempt from E2122: a zero can never be a laundered address.

pub fn main() i32 {
    let p: &i32 = 0usize as &i32
    if p as usize == 0 {
        return 7
    }
    return 1
}
