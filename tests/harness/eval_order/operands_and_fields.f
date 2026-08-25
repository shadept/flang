//! TEST: eval_order_operands_and_fields
//! EXIT: 0
//! STDOUT: -1
//! STDOUT: 1
//! STDOUT: 2
//! STDOUT: 20

// Pins spec 5.1.1 beyond call arguments: binary operands, struct-literal
// fields, and the operands of an index expression.

type Pair = struct {
    first: i32
    second: i32
}

fn tick(counter: &i32) i32 {
    counter.* = counter.* + 1
    return counter.*
}

fn tick_usize(counter: &usize) usize {
    counter.* = counter.* + 1
    return counter.*
}

pub fn main() i32 {
    // Left operand first: 1 - 2, not 2 - 1.
    let a: i32 = 0
    println(tick(&a) - tick(&a))

    // Struct fields initialize in written order.
    let b: i32 = 0
    const p = Pair { first = tick(&b), second = tick(&b) }
    println(p.first)
    println(p.second)

    // Index evaluated after the indexed value; xs[1] is 20.
    let c: usize = 0
    let xs: [i32; 3] = [10, 20, 30]
    println(xs[tick_usize(&c)])
    return 0
}
