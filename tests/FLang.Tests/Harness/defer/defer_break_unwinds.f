//! TEST: defer_break_unwinds
//! EXIT: 0
//! STDOUT: iter-0
//! STDOUT: iter-1
//! STDOUT: inner-break
//! STDOUT: iter-2
//! STDOUT: after-loop
//! STDOUT: outer

// `break` exits the loop body — every defer registered inside it (including
// in nested blocks) fires first, innermost out. After the loop, the
// function-level defer fires on the implicit return.

fn emit(tag: String) {
    println(tag)
}

pub fn main() i32 {
    defer emit("outer")

    for i in 0usize..5usize {
        defer emit(if i == 0usize { "iter-0" } else if i == 1usize { "iter-1" } else { "iter-2" })
        if i == 2usize {
            defer emit("inner-break")
            break
        }
    }

    emit("after-loop")
    return 0
}
