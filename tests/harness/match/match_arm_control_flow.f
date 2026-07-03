//! TEST: match_arm_control_flow
//! EXPECTED: 42

type Action = enum {
    Go(i32)
    Stop
}

// Test: return in match arm exits the function early
fn early_return(x: i32) i32 {
    let result = x match {
        0 => return 99,
        _ => x
    }
    return result
}

// Test: break in match arm exits the loop
fn loop_break() i32 {
    let found: i32 = 0
    loop {
        found = 33
        let action = Action.Stop
        action match {
            Stop => break,
            Go(v) => found = v
        }
    }
    return found
}

pub fn main() i32 {
    // early_return(0) = 99 (return in match arm)
    let a = early_return(0)
    if a != 99 { return 1 }

    // early_return(5) = 5 (normal path)
    let b = early_return(5)
    if b != 5 { return 2 }

    // loop_break() = 33 (break in match arm)
    let c = loop_break()
    if c != 33 { return 3 }

    // 99 - 5 - 33 - 19 = 42
    return a - b - c - 19
}
