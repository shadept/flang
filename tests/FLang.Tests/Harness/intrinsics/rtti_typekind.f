//! TEST: rtti_typekind
//! EXIT: 0

// Test that TypeKind is correctly set for different type categories

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
    let prim = i32
    let struc = Point

    // Primitive = 0, Struct = 2
    let result: i32 = kind_to_int(prim.kind) + kind_to_int(struc.kind)
    // 0 + 2 = 2
    return result - 2
}
