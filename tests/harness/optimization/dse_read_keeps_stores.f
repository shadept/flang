//! TEST: dse_read_keeps_stores
//! EXIT: 20

// DSE must not drop stores to an alloca that is still read.
// Any read (here via index) marks the alloca live, and all feeding
// stores must be preserved.

pub fn main() i32 {
    let arr: [i32; 3] = [10, 20, 30]
    return arr[1]
}
