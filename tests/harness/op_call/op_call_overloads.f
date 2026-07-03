//! TEST: op_call_overloads
//! EXIT: 50

// Multiple op_call overloads on the same type, dispatched by argument type.

type Adder = struct { base: i32 }

fn op_call(self: &Adder, x: i32) i32 {
    return self.base + x
}

fn op_call(self: &Adder, x: i32, y: i32) i32 {
    return self.base + x + y
}

pub fn main() i32 {
    let a = Adder { base = 10 }
    let one = a(5)         // 15
    let two = a(15, 10)    // 35
    return one + two       // 50
}
