//! TEST: anon_struct_type_return
//! EXIT: 42

fn make() struct { x: i32, y: i32 } {
    return .{ x = 42, y = 10 }
}

pub fn main() i32 {
    let p = make()
    return p.x
}
