//! TEST: fn_type_ref_slot
//! EXIT: 0

// A reference to a function-typed place writes the slot it names, as any `&T` does (RFC-037).

fn inc(x: i32) i32 {
    return x + 1
}

fn dbl(x: i32) i32 {
    return x * 2
}

fn set(slot: &fn(i32) i32, f: fn(i32) i32) {
    slot.* = f
}

pub fn main() i32 {
    let hs: [fn(i32) i32; 2] = [inc, inc]
    set(&hs[1], dbl)
    const g: fn(i32) i32 = hs[1]
    const h: fn(i32) i32 = hs[0]
    return g(5i32) + h(5i32) - 16
}
