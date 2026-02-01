//! TEST: array_to_slice_call_variable
//! EXIT: 5

// Array variable (not literal) coerces to slice when passed to function
fn takes_slice(s: u8[]) i32 {
    return s.len as i32
}

pub fn main() i32 {
    let arr: [u8; 5] = [1, 2, 3, 4, 5]
    return takes_slice(arr)
}
