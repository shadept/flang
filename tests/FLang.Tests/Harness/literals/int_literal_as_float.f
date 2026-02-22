//! TEST: int_literal_as_float
//! EXIT: 3

type Vec2 = struct {
    x: f32
    y: f64
}

fn sum(v: Vec2) f64 {
    return v.x + v.y
}

pub fn main() i32 {
    const v = Vec2 { x = 1, y = 2 }
    return sum(v) as i32
}
