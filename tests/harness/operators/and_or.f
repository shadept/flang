//! TEST: and_or
//! EXIT: 0

// Truth table for and/or + precedence verification

pub fn main() i32 {
    // and truth table
    let tt: bool = true and true
    let tf: bool = true and false
    let ft: bool = false and true
    let ff: bool = false and false

    if (!tt) { return 1 }
    if (tf) { return 2 }
    if (ft) { return 3 }
    if (ff) { return 4 }

    // or truth table
    let o_tt: bool = true or true
    let o_tf: bool = true or false
    let o_ft: bool = false or true
    let o_ff: bool = false or false

    if (!o_tt) { return 5 }
    if (!o_tf) { return 6 }
    if (!o_ft) { return 7 }
    if (o_ff) { return 8 }

    // Precedence: and binds tighter than or
    // true or false and false  =>  true or (false and false)  =>  true or false  =>  true
    let prec: bool = true or false and false
    if (!prec) { return 9 }

    // false and true or true  =>  (false and true) or true  =>  false or true  =>  true
    let prec2: bool = false and true or true
    if (!prec2) { return 10 }

    return 0
}
