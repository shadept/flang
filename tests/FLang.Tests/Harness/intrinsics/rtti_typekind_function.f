//! TEST: rtti_typekind_function
//! EXIT: 0

// TypeKind.Function variant exists and is matchable

import core.rtti

fn is_function(k: TypeKind) bool {
    return k match {
        Function => true,
        _ => false
    }
}

fn is_struct(k: TypeKind) bool {
    return k match {
        Struct => true,
        _ => false
    }
}

fn is_primitive(k: TypeKind) bool {
    return k match {
        Primitive => true,
        _ => false
    }
}

type Point = struct { x: i32, y: i32 }

pub fn main() i32 {
    if !is_primitive(i32.kind) { return 1 }
    if !is_struct(Point.kind) { return 2 }

    // Verify Function variant doesn't match for non-function types
    if is_function(i32.kind) { return 3 }
    if is_function(Point.kind) { return 4 }

    return 0
}
