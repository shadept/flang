//! TEST: slice_equality
//! EXIT: 5

// Slices compare element-wise: same length and `==` at every index.
pub fn main() i32 {
    let a: [i32; 3] = [1, 2, 3]
    let b: [i32; 3] = [1, 2, 3]
    let c: [i32; 3] = [1, 2, 4]
    const sa: i32[] = a
    const sb: i32[] = b
    const sc: i32[] = c
    let n: i32 = 0
    if sa == sb {
        n = n + 1
    }
    if !(sa == sc) {
        n = n + 2
    }
    if !(sa == sa[0..2]) {
        n = n + 2
    }
    return n
}
