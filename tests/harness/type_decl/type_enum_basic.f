//! TEST: type_enum_basic
//! EXIT: 1

type Color = enum {
    Red
    Green
    Blue
}

pub fn main() i32 {
    let c: Color = Color.Green
    return c match {
        Red => 0,
        Green => 1,
        Blue => 2
    }
}
