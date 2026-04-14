//! TEST: rtti_fields_count
//! EXIT: 2

// Test that Type(T).fields.len returns the correct field count

import core.rtti

type Point = struct {
    x: i32
    y: i32
}

fn field_count(t: Type($T)) i32 {
    return t.fields.len as i32
}

pub fn main() i32 {
    return field_count(Point)
}
