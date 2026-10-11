//! TEST: self_in_struct
//! EXIT: 6

import std.option

// `Self` in a named struct or enum is the type applied to its own parameters.
type Node = struct(T) {
    value: T
    next: &Self?
}

type Expr = enum {
    Lit(i32)
    Add(&Self, &Self)
}

fn eval(e: &Expr) i32 {
    return e.* match {
        Lit(v) => v
        Add(a, b) => eval(a) + eval(b)
    }
}

pub fn main() i32 {
    const tail = Node(i32) { value = 2i32, next = null }
    const head = Node(i32) { value = 1i32, next = Some(&tail) }
    const one = Expr.Lit(1)
    const two = Expr.Lit(2)
    const sum = Expr.Add(&one, &two)
    return head.value + head.next.unwrap().value + eval(&sum)
}
