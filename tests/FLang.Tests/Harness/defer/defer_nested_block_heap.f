//! TEST: defer_nested_block_heap
//! EXIT: 0
//! STDOUT: iter 0
//! STDOUT: iter 2
//! STDOUT: outer-done

// Regression: a `defer` that owns a heap resource allocated INSIDE a nested
// block (here an `if` body nested inside a `for` body) used to lower to a
// function-exit cleanup. The generated C referenced an `alloca_N` declared
// in the nested scope — C rejected it as `undeclared identifier`, and on
// targets that accepted it the deinit fired past the StringBuilder's live
// range, scrambling memory.
//
// Fix: every `BlockExpressionNode` is its own defer scope. The `defer sb…`
// inside the `if` must fire at the `if`'s closing brace, before the next
// loop iteration re-enters the scope and allocates a fresh builder.

import std.string_builder

pub fn main() i32 {
    let outer_sb = string_builder(16)
    defer outer_sb.deinit()
    outer_sb.append("outer-done")

    for i in 0usize..4usize {
        if i % 2 == 0 {
            let sb = string_builder(32)
            defer sb.deinit()
            sb.append("iter ")
            sb.append(i)
            println(sb.as_view())
        }
    }

    println(outer_sb.as_view())
    return 0
}
