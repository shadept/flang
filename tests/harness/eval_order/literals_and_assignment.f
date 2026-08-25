//! TEST: eval_order_literals_and_assignment
//! EXIT: 0
//! STDOUT: 1
//! STDOUT: 2
//! STDOUT: place=1
//! STDOUT: value=2

// Array-literal elements and the two halves of an assignment. The assignment
// case pins which side runs first, which is the part of left-to-right that is
// easiest to get wrong.

fn tick(counter: &i32) i32 {
    counter.* = counter.* + 1
    return counter.*
}

fn tick_usize(counter: &usize, log: &i32, order: &i32) usize {
    order.* = order.* + 1
    log.* = order.*
    counter.* = counter.* + 1
    return 0
}

fn tick_value(log: &i32, order: &i32) i32 {
    order.* = order.* + 1
    log.* = order.*
    return 99
}

pub fn main() i32 {
    // Elements in written order.
    let a: i32 = 0
    let xs: [i32; 2] = [tick(&a), tick(&a)]
    println(xs[0])
    println(xs[1])

    // Which side of `=` runs first.
    let order: i32 = 0
    let place_at: i32 = 0
    let value_at: i32 = 0
    let idx: usize = 0
    let dst: [i32; 2] = [0, 0]
    dst[tick_usize(&idx, &place_at, &order)] = tick_value(&value_at, &order)
    print("place=")
    println(place_at)
    print("value=")
    println(value_at)
    return 0
}
