//! TEST: type_enum_generic
//! EXIT: 42

type Maybe = enum(T) {
    Just(T)
    Nothing
}

fn unwrap_or(opt: Maybe($T), default_val: T) T {
    return opt match {
        Just(v) => v,
        Nothing => default_val
    }
}

pub fn main() i32 {
    let a: Maybe(i32) = Maybe.Just(42)
    let b: Maybe(i32) = Maybe.Nothing
    return unwrap_or(a, 0)
}
