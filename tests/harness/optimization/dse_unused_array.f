//! TEST: dse_unused_array
//! EXIT: 5

// An unused local array should be eliminated entirely by DSE:
// the alloca, three copytooffset stores, and the trailing DCE sweep
// all collapse into just the return.

pub fn main() i32 {
    let _arr: [i32; 3] = [10, 20, 30]
    return 5
}
