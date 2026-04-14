//! TEST: rtti_fields_primitive
//! EXIT: 0

// Test that primitive types have 0 fields

import core.rtti

fn field_count(t: Type($T)) i32 {
    return t.fields.len as i32
}

pub fn main() i32 {
    return field_count(i32)
}
