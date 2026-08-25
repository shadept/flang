//! TEST: eval_order_args_left_to_right
//! EXIT: 0
//! STDOUT: 1
//! STDOUT: 2
//! STDOUT: 3
//! STDOUT: 4
//! STDOUT: 5

// Pins spec 5.1.1: call arguments evaluate left to right, each fully before
// the next. C leaves this unspecified, so the backend has to enforce it.

fn tick(counter: &i32) i32 {
    counter.* = counter.* + 1
    return counter.*
}

fn show3(a: i32, b: i32, c: i32) {
    println(a)
    println(b)
    println(c)
}

fn show2(a: i32, b: i32) {
    println(a)
    println(b)
}

pub fn main() i32 {
    let n: i32 = 0
    show3(tick(&n), tick(&n), tick(&n))
    show2(tick(&n), tick(&n))
    return 0
}
