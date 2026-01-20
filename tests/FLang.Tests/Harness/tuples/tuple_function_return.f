//! TEST: tuple_function_return
//! EXIT: 30

// Tuples can be returned from functions

fn make_pair() (i32, i32) {
    return (10, 20)
}

pub fn main() i32 {
    let p = make_pair()
    return p.0 + p.1
}
