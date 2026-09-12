//! TEST: if_directive_type_param_kind_name
//! EXIT: 6

// `type_info(T).kind` and `type_info(T).name` in a generic body's `#if` read the same values the
// runtime descriptor carries: the short nominal name and the `TypeKind` discriminant.

import core.rtti

type Point = struct {
    x: i32
}

type Shape = enum {
    Dot
    Line(i32)
}

fn classify(x: &$T) i32 {
    #if type_info(T).kind == TypeKind.Struct and type_info(T).name == "Point" {
        return 1
    } else {
        #if type_info(T).kind == TypeKind.Enum {
            return 2
        } else {
            #if type_info(T).name == "i32" {
                return 3
            } else {
                return 100
            }
        }
    }
}

pub fn main() i32 {
    let p = Point { x = 0 }
    let s = Shape.Dot
    let n: i32 = 0
    return classify(&p) + classify(&s) + classify(&n)
}
