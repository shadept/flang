//! TEST: generic_mangling_order
//! EXIT: 132

// Single generic function that forwards to overloaded helper.
// This avoids ambiguous generic overloads while still requiring
// two distinct specializations (A=i32,B=u64) and (A=u64,B=i32).

pub fn pick(a: $A, b: $B) i32 {
    return helper(a, b)
}

pub fn helper(a: i32, b: u64) i32 { return 84 }
pub fn helper(a: u64, b: i32) i32 { return 48 }

pub fn main() i32 {
    let x: i32 = pick(1 as i32, 0 as u64)
    let y: i32 = pick(1 as u64, 0 as i32)
    return x + y
}
