//! TEST: enum_basic
//! EXIT: 1

enum Color {
    Red
    Green
    Blue
}

pub fn main() i32 {
    let c: Color = Color.Green
    return get_color_value(c)
}

fn get_color_value(c: Color) i32 {
    return c match {
        Red => 0,
        Green => 1,
        Blue => 2
    }
}

