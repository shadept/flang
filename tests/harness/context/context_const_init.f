//! TEST: context_const_init
//! EXIT: 6

// A module constant's initializer runs under the root context.

context base: i32 = 6

fn read() i32 {
    return context.base
}

const seen: i32 = read()

pub fn main() i32 {
    return context(base = 1i32) { seen }
}
