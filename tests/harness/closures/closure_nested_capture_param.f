//! TEST: closure_nested_capture_param
//! EXIT: 30

// An inner closure capturing the enclosing closure's parameter and a name from the function body.
pub fn main() i32 {
    let base = 10
    let outer = { x: i32 =>
        let inner = { y: i32 => y + base }
        inner(x) + base
    }
    return outer(10)
}
