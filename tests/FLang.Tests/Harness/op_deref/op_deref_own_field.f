//! TEST: op_deref_own_field
//! EXIT: 99

// Own fields take priority over op_deref — accessing 'tag' should
// return the wrapper's own field, not look through op_deref.

type Tagged = struct(T) { tag: i32, __value: T }

fn op_deref(self: &Tagged($T)) &T {
    return &self.__value
}

type Point = struct { x: i32, y: i32 }

pub fn main() i32 {
    let t = Tagged(Point) { tag = 99, __value = Point { x = 1, y = 2 } }
    return t.tag
}
