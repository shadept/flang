//! TEST: ufcs_basic_value
//! EXIT: 15

// UFCS requires reference parameters
fn double(x: &i32) i32 {
    return x.* * 2
}

fn add_five(x: &i32) i32 {
    return x.* + 5
}

pub fn main() i32 {
    let n: i32 = 5
    // UFCS chaining: n.double().add_five() -> add_five(&double(&n))
    // Lowering should introduce temp for intermediate result
    return n.double().add_five()
}
