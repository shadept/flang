//! TEST: directives_foreign_struct
//! STDOUT: 30
//! EXIT: 0

// Foreign struct — layout locked to C ABI, uses inline directive syntax.
// Without -I headers, the struct is emitted in the generated C code.
pub type Point = #foreign struct {
    x: i32,
    y: i32,
}

// Regular struct can contain foreign struct
type Wrapper = struct {
    p: Point,
    label: i32,
}

fn sum_wrapper(w: &Wrapper) i32 {
    return w.p.x + w.p.y
}

pub fn main() i32 {
    let p = Point { x = 10, y = 20 }
    let w = Wrapper { p = p, label = 99 }
    println(sum_wrapper(&w))
    return 0
}
