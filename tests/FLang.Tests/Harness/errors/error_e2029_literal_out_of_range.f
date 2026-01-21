//! TEST: error_e2029_literal_out_of_range
//! COMPILE-ERROR: E2029

fn takes_u8_slice(s: u8[]) i32 { return s.len as i32 }

pub fn main() i32 {
    let result: i32 = takes_u8_slice([256; 10])  // ERROR: 256 doesn't fit in u8
    return result
}
