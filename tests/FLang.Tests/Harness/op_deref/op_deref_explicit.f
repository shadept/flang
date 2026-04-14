//! TEST: op_deref_explicit
//! EXIT: 42

type Box = struct(T) { __value: T }

fn op_deref(self: &Box($T)) &T {
    return &self.__value
}

pub fn main() i32 {
    let b = Box(i32) { __value = 42 }
    return b.*
}
