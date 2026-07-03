//! TEST: autoderef_nested
//! EXIT: 42

type Inner = struct {
    value: i32
}

type Outer = struct {
    inner: Inner
}

pub fn getValue(o: &Outer) i32 {
    // Auto-deref: o.inner.value on &Outer accesses nested fields through pointer
    return o.inner.value
}

pub fn main() i32 {
    let o: Outer = Outer { inner = Inner { value = 42 } }
    return getValue(&o)
}
