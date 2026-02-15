//! TEST: type_struct_basic
//! EXIT: 42

type Foo = struct {
    x: i32,
    y: i32
}

pub fn main() i32 {
    let f: Foo = Foo { x = 42, y = 10 }
    return f.x
}
