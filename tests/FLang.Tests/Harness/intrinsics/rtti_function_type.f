//! TEST: rtti_function_type
//! EXIT: 0

// Test that structs with function fields have correct RTTI

import core.rtti
import core.string

type Handler = struct {
    on_data: fn(u8[], usize) bool
    on_close: fn() bool
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

fn check_handler(t: Type($T)) i32 {
    // Handler is a Struct
    if kind_to_int(t.kind) != 2 { return 1 }

    // 2 fields
    if t.fields.len != 2 { return 2 }

    // Field names
    if t.fields[0].name != "on_data" { return 3 }
    if t.fields[1].name != "on_close" { return 4 }

    // Struct has no params (it's not a function type)
    if t.params.len != 0 { return 5 }

    // Struct has null return_type
    if t.return_type as usize != 0 { return 6 }

    return 0
}

pub fn main() i32 {
    return check_handler(Handler)
}
