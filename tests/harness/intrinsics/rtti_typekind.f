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

fn get_kind(t: Type($T)) i32 {
    return kind_to_int(t.kind)
}

pub fn main() i32 {
    // Primitive = 0, Struct = 2
    let result: i32 = get_kind(i32) + get_kind(Point)
    // 0 + 2 = 2
    return result - 2
}
