//! TEST: rtti_identity
//! EXIT: 31

// Descriptors are static and one per type (ADR-0001): `type_info` and `type_of` return `&TypeInfo`,
// and two are the same type exactly when the references are equal - across call sites, through a
// value, and through a field's `type_info`.

import core.rtti

type Point = struct {
    x: i32
    y: i32
}

fn point_info() &TypeInfo {
    return type_info(Point)
}

pub fn main() i32 {
    let n: u32 = 4
    let p = Point { x = 1, y = 2 }
    let score: i32 = 0
    if type_of(n) == type_info(u32) {
        score = score + 1
    }
    if type_info(u32) != type_info(i32) {
        score = score + 2
    }
    if point_info() == type_info(Point) {
        score = score + 4
    }
    if type_info(Point).fields[0].type_info == type_info(i32) {
        score = score + 8
    }
    if type_of(p) == type_info(Point) {
        score = score + 16
    }
    return score
}
