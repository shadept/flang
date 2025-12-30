//! TEST: enum_generic
//! EXIT: 15

enum Result(T, E) {
    Ok(T)
    Err(E)
}

pub fn main() i32 {
    let r1: Result(i32, i32) = Result.Ok(15)
    let r2: Result(i32, i32) = Result.Err(99)
    
    let v1 = unwrap_or(r1, 0)
    let v2 = unwrap_or(r2, 0)
    
    return v1 + v2
}

fn unwrap_or(r: Result($T, $E), default: T) T {
    return r match {
        Ok(value) => value,
        Err(_) => default
    }
}

