//! TEST: global_const_vtable
//! EXIT: 7

struct Operations {
    add: fn(i32, i32) i32
    sub: fn(i32, i32) i32
}

fn do_add(a: i32, b: i32) i32 {
    return a + b
}

fn do_sub(a: i32, b: i32) i32 {
    return a - b
}

const ops = Operations {
    add = do_add,
    sub = do_sub
}

pub fn main() i32 {
    let result = ops.add(3, 4)
    return result
}
