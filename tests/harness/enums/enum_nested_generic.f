//! TEST: enum_nested_generic
//! EXIT: 99

type Option(T) = enum {
    Some(T)
    None
}

type Result(T, E) = enum {
    Ok(T)
    Err(E)
}

pub fn main() i32 {
    let r: Result(Option(i32), i32) = Result.Ok(Option.Some(99))

    let val = r match {
        Ok(opt) => opt match {
            Some(v) => v,
            None => 0
        },
        Err(e) => e
    }

    return val
}
