//! TEST: autoderef_chain
//! EXIT: 77

// Define in dependency order for C codegen
type Inner = struct {
    value: i32
}

type Outer = struct {
    inner: Inner
}

pub fn getValue(o: &Outer) i32 {
    // Auto-deref and nested field access: o.inner.value
    return o.inner.value
}

pub fn main() i32 {
    let o: Outer = Outer {
        inner = Inner { value = 77 }
    }
    return getValue(&o)
}
