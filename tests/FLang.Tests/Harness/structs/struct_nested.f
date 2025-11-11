//! TEST: struct_nested
//! EXIT: 42

struct Inner {
    value: i32
}

struct Outer {
    inner: Inner,
    extra: i32
}

pub fn main() i32 {
    let inner: Inner = Inner { value: 42 }
    let outer: Outer = Outer { inner: inner, extra: 10 }
    return outer.inner.value
}
