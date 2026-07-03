//! TEST: comptime_int_chain
//! EXIT: 0

fn takes_u32(x: u32) u32 { return x }

pub fn main() i32 {
    let c = 0
    let b = c
    let a = b
    let result = takes_u32(a)
    return 0
}
