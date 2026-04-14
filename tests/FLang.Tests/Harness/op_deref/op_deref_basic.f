//! TEST: op_deref_basic
//! EXIT: 35

type Wrapper = struct(T) { __value: T }

fn op_deref(self: &Wrapper($T)) &T {
    return &self.__value
}

type Point = struct { x: i32, y: i32 }

pub fn main() i32 {
    let w = Wrapper(Point) { __value = Point { x = 10, y = 25 } }
    return w.x + w.y
}
