//! TEST: copy_to_overlapping
//! EXIT: 110

// `copy_to` may overlap its destination: shifting right by one keeps every element.
pub fn main() i32 {
    let a: [i32; 4] = [1, 2, 3, 0]
    const s: i32[] = a
    copy_to(s[0..3], s[1..4])
    return a[0] * 100 + a[1] * 10 + a[2] - a[3] + 1
}
