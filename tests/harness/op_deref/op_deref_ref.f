//! TEST: op_deref_ref
//! EXIT: 7

// op_deref on &Wrapper — auto-deref through the reference, then op_deref.

type Box = struct(T) { __value: T }

fn op_deref(self: &Box($T)) &T {
    return &self.__value
}

fn get_value(b: &Box(i32)) i32 {
    return b.__value
}

pub fn main() i32 {
    let b = Box(i32) { __value = 7 }
    return get_value(&b)
}
