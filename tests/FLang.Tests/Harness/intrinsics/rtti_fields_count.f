//! TEST: rtti_fields_count
//! EXIT: 2

// Test that Type(T).fields.len returns the correct field count
// struct Point { x: i32, y: i32 } has 2 fields

import core.rtti

struct Point {
    x: i32
    y: i32
}

pub fn main() i32 {
    let t = Point
    return t.fields.len as i32
}
