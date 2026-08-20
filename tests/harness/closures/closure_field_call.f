//! TEST: closure_field_call
//! EXIT: 90

// A capturing closure stored in a struct field is callable directly through
// the field: `h.f(x)` dispatches via the closure type's op_call, without
// needing the `let g = h.f; g(x)` local-copy workaround.

type Holder = struct(F) {
    f: F,
}

fn make_holder(f: $F) Holder(F) {
    return .{ f = f }
}

// Generic fn body: the field's type is a TypeVar at template time and only
// becomes the concrete __Closure_N at specialization (the iterator-adapter
// pattern in std.iter).
fn invoke(h: &Holder($F), x: i32) i32 {
    return h.f(x)
}

pub fn main() i32 {
    let scale = 10
    let h = make_holder(fn(x: i32) i32 { x * scale })

    // Direct field call
    let a = h.f(2)

    // Through a reference receiver
    let hr = &h
    let b = hr.f(4)

    // Through a generic fn
    let c = invoke(&h, 3)

    return a + b + c
}
