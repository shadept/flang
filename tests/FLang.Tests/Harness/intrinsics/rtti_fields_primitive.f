//! TEST: rtti_fields_primitive
//! EXIT: 0

// Test that primitive types have 0 fields

import core.rtti

pub fn main() i32 {
    let t = i32
    return t.fields.len as i32
}
