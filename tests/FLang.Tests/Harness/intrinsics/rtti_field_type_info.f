//! TEST: rtti_field_type_info
//! EXIT: 0

// Test that FieldInfo.type_info points to the correct TypeInfo

import core.rtti

type Point = struct {
    x: i32
    y: i32
}

fn kind_to_int(k: TypeKind) i32 {
    return k match {
        Primitive => 0,
        Array => 1,
        Struct => 2,
        Enum => 3,
        Function => 4
    }
}

pub fn main() i32 {
    let t = Point

    // Point has 2 fields
    if t.fields.len != 2 { return 1 }

    // field type_info should be non-null
    let x_type = t.fields[0].type_info
    if x_type as usize == 0 { return 2 }

    // x is i32 => kind == Primitive
    if kind_to_int(x_type.kind) != 0 { return 3 }

    // x type name is "i32"
    if x_type.name != "i32" { return 4 }

    // y type_info should also be i32
    let y_type = t.fields[1].type_info
    if y_type as usize == 0 { return 5 }
    if y_type.name != "i32" { return 6 }

    return 0
}
