//! TEST: array_repeat_in_generic
//! EXIT: 7
// Regression: `[V; N]` repeat-literal used inside a monomorphized generic
// function used to ICE during specialization (docs/known-issues.md).

fn inner(_tag: $T) i32 {
    let a: [i32; 4] = [7; 4]
    return a[0]
}

pub fn main() i32 {
    return inner(0i32)
}
