//! TEST: anon_struct_type_param
//! EXIT: 30

fn sum(p: struct { a: i32, b: i32 }) i32 {
    return p.a + p.b
}

pub fn main() i32 {
    return sum(.{ a = 10, b = 20 })
}
