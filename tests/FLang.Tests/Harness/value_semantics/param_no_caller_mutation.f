//! TEST: param_no_caller_mutation
//! EXIT: 0
//! STDOUT: 10
//! STDOUT: 99

// Passing a struct to a function must never mutate the caller's value.
// Callee gets implicit reference; writes trigger copy-on-write.

struct Box {
    val: i32
}

fn mutate_box(b: Box) i32 {
    b.val = 99         // copy-on-write: creates local shadow
    return b.val       // reads from shadow
}

pub fn main() i32 {
    let x = Box { val = 10 }
    let result = mutate_box(x)

    println(x.val)       // must still be 10 (caller unaffected)
    println(result)       // must be 99

    if x.val != 10 { return 1 }
    if result != 99 { return 2 }
    return 0
}
