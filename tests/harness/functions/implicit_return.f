//! TEST: implicit_return
//! STDOUT: 42
//! STDOUT: 10
//! STDOUT: 7
pub fn add(a: i32, b: i32) i32 {
    a + b
}

pub fn max(a: i32, b: i32) i32 {
    if (a > b) { a } else { b }
}

pub fn compute() i32 {
    let x: i32 = 3
    let y: i32 = 4
    x + y
}

pub fn main() {
    println(add(40, 2))
    println(max(10, 5))
    println(compute())
}
