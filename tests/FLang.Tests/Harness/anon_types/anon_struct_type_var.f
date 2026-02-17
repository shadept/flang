//! TEST: anon_struct_type_var
//! EXIT: 52

pub fn main() i32 {
    let p: struct { x: i32, y: i32 } = .{ x = 42, y = 10 }
    return p.x + p.y
}
