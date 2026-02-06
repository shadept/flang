//! TEST: struct_slice_field_init
//! EXIT: 5

struct Wrapper {
    data: u8[],
    pos: usize
}

pub fn main() i32 {
    let arr: [u8; 5] = [1, 2, 3, 4, 5]
    let w = Wrapper { data = arr, pos = 0 }
    let n: usize = w.data.len
    return n as i32
}
