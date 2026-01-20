//! TEST: tuple_function_param
//! EXIT: 30

// Tuples can be passed as function parameters

fn sum_pair(p: (i32, i32)) i32 {
    return p.0 + p.1
}

pub fn main() i32 {
    let t = (10, 20)
    return sum_pair(t)
}
