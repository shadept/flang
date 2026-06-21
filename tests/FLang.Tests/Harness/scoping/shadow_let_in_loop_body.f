//! TEST: shadow_let_in_loop_body
//! EXIT: 0

// A `let` inside a loop body is scoped to that body: a read of the same name
// after the loop must resolve to the outer binding, not the loop-local slot.
// Regression — lowering reused one storage slot for both, so the post-loop read
// returned the inner value (or uninitialised garbage when the body never ran).

fn pick() i32 {
    return 7
}

fn main() i32 {
    let id = pick()
    let n: i32 = 3
    for i in 0..n {
        let id = i
        if id > 100 {
            return 1
        }
    }
    return id - 7
}
