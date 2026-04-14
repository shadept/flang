//! TEST: op_deref_nested
//! EXIT: 42

// Two layers of wrappers — chained op_deref resolves through both.

type Outer = struct(T) { __inner: T }
type Inner = struct(T) { __value: T }

fn op_deref(self: &Outer($T)) &T {
    return &self.__inner
}

fn op_deref(self: &Inner($T)) &T {
    return &self.__value
}

pub fn main() i32 {
    let o = Outer(Inner(i32)) { __inner = Inner(i32) { __value = 42 } }
    return o.__value
}
