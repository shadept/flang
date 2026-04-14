//! TEST: op_deref_ufcs_own
//! EXIT: 10

// Methods on the wrapper type itself should resolve directly,
// NOT go through op_deref.

type Box = struct(T) { __value: T }

fn op_deref(self: &Box($T)) &T {
    return &self.__value
}

fn tag(self: &Box($T)) i32 {
    return 10
}

pub fn main() i32 {
    let b = Box(i32) { __value = 42 }
    return b.tag()
}
