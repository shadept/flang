//! TEST: comptime_array_to_slice
//! EXIT: 0

fn takes_u8_slice(s: u8[]) i32 { return s.len as i32 }
fn takes_i32_slice(s: i32[]) i32 { return s.len as i32 }

pub fn main() i32 {
    let len1: i32 = takes_u8_slice([0; 16])
    let len2: i32 = takes_i32_slice([42; 10])
    if (len1 != 16) {
        return 1
    }
    if (len2 != 10) {
        return 2
    }
    return 0
}
