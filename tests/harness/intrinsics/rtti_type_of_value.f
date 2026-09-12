//! TEST: rtti_type_of_value
//! EXIT: 3

// `type_of(value)` at run time is the descriptor of the value's type; `type_info(Type)` is the
// descriptor of a type. Both read the same record.

import core.rtti

type Point = struct {
    x: i32
}

pub fn main() i32 {
    let n: i32 = 4
    let p = Point { x = 1 }
    let score: i32 = 0
    if type_of(n).name == "i32" {
        score = score + 1
    }
    if type_of(p).kind == TypeKind.Struct and type_info(Point).name == type_of(p).name {
        score = score + 2
    }
    return score
}
