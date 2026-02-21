//! TEST: rtti_struct_fn_fields
//! EXIT: 0

// Structs with multiple function-typed fields report correct field count and names

import core.rtti
import core.string

type MathOps = struct {
    add: fn(i32, i32) i32
    sub: fn(i32, i32) i32
    negate: fn(i32) i32
}

pub fn main() i32 {
    let t = MathOps

    // Should have 3 fields
    if t.fields.len != 3 { return 1 }

    // Check field names
    if t.fields[0].name != "add" { return 2 }
    if t.fields[1].name != "sub" { return 3 }
    if t.fields[2].name != "negate" { return 4 }

    return 0
}
