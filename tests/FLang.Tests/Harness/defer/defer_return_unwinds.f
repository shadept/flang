//! TEST: defer_return_unwinds
//! EXIT: 0
//! STDOUT: body
//! STDOUT: inner
//! STDOUT: middle
//! STDOUT: outer

// `return` unwinds every active defer scope from innermost to outermost.
// LIFO order: the defer registered deepest in the block nest fires first.

fn emit(tag: String) {
    println(tag)
}

fn run() {
    defer emit("outer")
    if true {
        defer emit("middle")
        if true {
            defer emit("inner")
            emit("body")
            return
        }
    }
}

pub fn main() i32 {
    run()
    return 0
}
