//! TEST: fn_type_call_target_not_unused
//! EXIT: 7
//! NO-COMPILE-WARNING: W1001

// A local used only in callee position is a use — must not warn W1001

type Holder = struct {
    f: fn(i32) i32
}

fn add_two(x: i32) i32 {
    return x + 2
}

fn invoke(h: &Holder, x: i32) i32 {
    let g = h.f
    return g(x)
}

pub fn main() i32 {
    let h = Holder { f = add_two }
    return invoke(&h, 5)
}
