//! TEST: closure_nested_capture_param
//! EXIT: 30

// An inner closure capturing the enclosing closure's parameter and a name from the function body.
pub fn main() i32 {
    let base = 10
    let outer = fn(x: i32) i32 {
        let inner = fn(y: i32) i32 { y + base }
        return inner(x) + base
    }
    return outer(10)
}
