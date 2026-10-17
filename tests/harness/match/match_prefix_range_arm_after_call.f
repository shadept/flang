//! TEST: match_prefix_range_arm_after_call
//! EXIT: 32

// An arm opening with `..` starts its own range pattern; it does not continue the arm above as a
// range expression.
fn double(n: i32) i32 {
    return n * 2
}

fn classify(n: i32) i32 {
    return n match {
        10 => double(5)
        ..0 => 1
        else => 0
    }
}

pub fn main() i32 {
    const total = classify(10) + classify(-3) * 22 + classify(7)
    return total
}
