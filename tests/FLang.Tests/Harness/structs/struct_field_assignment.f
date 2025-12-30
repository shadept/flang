//! TEST: struct_field_assignment
//! EXIT: 42

struct Counter {
    value: isize
}

pub fn main() i32 {
    let c = Counter { value = 0 }
    c.value = 42
    return c.value as i32
}
