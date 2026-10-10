//! TEST: as_bytes_view
//! EXIT: 9

// `as_bytes` views a copyable slice's memory: two `u32`s are eight bytes, the low one first.
pub fn main() i32 {
    let a: [u32; 2] = [1u32, 0u32]
    const s: u32[] = a
    const b = as_bytes(s)
    return b.len as i32 + b[0] as i32
}
