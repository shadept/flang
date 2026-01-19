//! TEST: ufcs_basic_value
//! EXIT: 15

// A free function that takes a value as first parameter
fn double(x: i32) i32 {
    return x * 2
}

fn add_five(x: i32) i32 {
    return x + 5
}

pub fn main() i32 {
    let n: i32 = 5
    // UFCS: n.double() -> double(n)
    return n.double().add_five()
}
