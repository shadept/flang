//! TEST: enum_naked_negative
//! EXIT: 1

type Sign = enum {
    Negative = -1
    Zero = 0
    Positive = 1
}

pub fn main() i32 {
    let s: Sign = Sign.Positive
    return s match {
        Negative => -1,
        Zero => 0,
        Positive => 1
    }
}
