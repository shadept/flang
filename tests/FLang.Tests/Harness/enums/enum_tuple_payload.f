//! TEST: enum_tuple_payload
//! EXIT: 42

// Test that a genuine tuple used as a single enum variant payload
// is NOT flattened into multiple bindings.

type Result = enum(T, E) {
    Ok(T)
    Err(E)
}

pub fn main() i32 {
    let r: Result((i32, i32), i32) = Result.Ok((10, 32))

    let val = r match {
        Ok(pair) => pair.0 + pair.1,
        Err(e) => e
    }

    return val
}
