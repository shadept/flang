//! TEST: rtti_enum_variants
//! EXIT: 0

// Enums report their variants through `TypeInfo.variants` — the same shape
// templates read at expansion time (RFC-021 §5). `fields` stays empty.

import core.rtti
import core.string

type Color = enum {
    Red
    Green
    Blue
}

fn check(t: Type($T)) i32 {
    if t.kind != TypeKind.Enum { return 1 }
    if t.variants.len != 3 { return 2 }
    if t.variants[0].name != "Red" { return 3 }
    if t.variants[1].name != "Green" { return 4 }
    if t.variants[2].name != "Blue" { return 5 }
    if t.fields.len != 0 { return 6 }
    return 0
}

pub fn main() i32 {
    return check(Color)
}
