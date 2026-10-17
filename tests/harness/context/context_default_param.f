//! TEST: context_default_param
//! EXIT: 37

// A parameter default may read a context field, declared anywhere in the program. It evaluates at
// the call, under the caller's context.

fn read(x: i32 = context.level) i32 {
    return x
}

context level: i32 = 7

pub fn main() i32 {
    const a: i32 = read()
    const b: i32 = context(level = 30i32) { read() }
    return a + b
}
