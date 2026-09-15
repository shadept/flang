//! TEST: closure_capture_param_copy_on_write
//! EXIT: 3

type Pt = struct {
    x: i32
    y: i32
}

fn bump(p: Pt) i32 {
    let f = fn() { p.x = p.x + 10 }
    f()
    return p.x
}

// A closure writing a captured parameter writes the function's own copy, never the caller's value.
pub fn main() i32 {
    let p = Pt { x = 3, y = 0 }
    let _n = bump(p)
    return p.x
}
