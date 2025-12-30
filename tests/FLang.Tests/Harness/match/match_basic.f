//! TEST: match_basic
//! EXIT: 5

enum Value {
    Some(i32)
    None
}

pub fn main() i32 {
    let v1: Value = Value.Some(5)
    let v2: Value = Value.None
    
    // All variants covered - exhaustive
    let r1 = v1 match {
        Some(x) => x,
        None => 0,
    }
    
    let r2 = v2 match {
        Some(x) => x,
        None => 0,
    }
    
    return r1 + r2
}

