//! TEST: struct_nested
//! EXIT: 42

type Inner = struct {
    value: i32
}

type Outer = struct {
    inner: Inner,
    extra: i32
}

pub fn main() i32 {
    let inner: Inner = Inner { value = 42 }
    let outer: Outer = Outer { inner = inner, extra = 10 }
    return outer.inner.value
}
