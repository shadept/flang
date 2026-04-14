//! TEST: op_deref_ufcs
//! EXIT: 5

type Box = struct(T) { __value: T }

fn op_deref(self: &Box($T)) &T {
    return &self.__value
}

type Point = struct { x: i32, y: i32 }

fn length_squared(self: &Point) i32 {
    return self.x * self.x + self.y * self.y
}

pub fn main() i32 {
    let b = Box(Point) { __value = Point { x = 1, y = 2 } }
    return b.length_squared()
}
