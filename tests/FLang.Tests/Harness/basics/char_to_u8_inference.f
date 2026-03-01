//! TEST: char_to_u8_inference
//! EXIT: 97

fn takes_u8(v: u8) u8 { return v }
fn takes_char(v: char) char { return v }

pub fn main() i32 {
    // 'a' inferred as u8 from variable type annotation
    let x: u8 = 'a'

    // 'b' inferred as char from function parameter type
    let y = takes_char('b')

    // 'c' inferred as u8 from function parameter type
    let z = takes_u8('c')

    // Char arithmetic still works: char + char = char
    let w: char = 'A'
    let q = w + 1 as char

    return x as i32
}
