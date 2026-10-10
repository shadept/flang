//! TEST: copy_to_short_destination
//! EXIT: 1
//! STDOUT: destination shorter than source

// A destination shorter than the source panics rather than copying a prefix.
pub fn main() i32 {
    let a: [i32; 3] = [1, 2, 3]
    let b: [i32; 2] = [0, 0]
    const src: i32[] = a
    const dst: i32[] = b
    copy_to(src, dst)
    return 0
}
