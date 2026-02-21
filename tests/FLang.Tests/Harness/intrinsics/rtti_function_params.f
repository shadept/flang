//! TEST: rtti_function_params
//! EXIT: 0

// Test that function type RTTI has correct params and return_type

import core.rtti

type Handler = struct {
    on_data: fn(i32, bool) bool
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
    let t = Handler

    // Handler has 1 field
    if t.fields.len != 1 { return 1 }

    // Get the function type info via the field
    let fn_type = t.fields[0].type_info
    if fn_type as usize == 0 { return 2 }

    // It should be a Function type
    if kind_to_int(fn_type.kind) != 4 { return 3 }

    // It should have 2 params
    if fn_type.params.len != 2 { return 4 }

    // First param type_info should be i32
    let p0 = fn_type.params[0].type_info
    if p0 as usize == 0 { return 5 }
    if p0.name != "i32" { return 6 }

    // Second param type_info should be bool
    let p1 = fn_type.params[1].type_info
    if p1 as usize == 0 { return 7 }
    if p1.name != "bool" { return 8 }

    // return_type should be bool
    let ret = fn_type.return_type
    if ret as usize == 0 { return 9 }
    if ret.name != "bool" { return 10 }

    return 0
}
