//! TEST: result_unwrap
//! EXIT: 42

import std.result

pub fn main() i32 {
    let r: Result(i32, i32) = Result.Ok(42)

    // unwrap should return the Ok value
    let value = r.unwrap()

    return value
}
