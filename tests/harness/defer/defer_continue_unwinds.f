//! TEST: defer_continue_unwinds
//! EXIT: 0
//! STDOUT: inner:1
//! STDOUT: body:0
//! STDOUT: body:1
//! STDOUT: body:2
//! STDOUT: outer

// `continue` jumps back to the loop head, escaping every scope between the
// jump and the loop body. Defers registered in those scopes must fire before
// the jump — innermost first — and must NOT fire again on subsequent
// iterations that don't re-register them.

fn emit(tag: String) {
    println(tag)
}

pub fn main() i32 {
    defer emit("outer")

    for i in 0usize..3usize {
        defer emit(if i == 0usize { "body:0" } else if i == 1usize { "body:1" } else { "body:2" })
        if i == 1usize {
            defer emit("inner:1")
            continue
        }
    }

    return 0
}
