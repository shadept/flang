//! TEST: op_call_value_receiver
//! EXIT: 42

// op_call with value receiver (self: T, not &T) — consumes the receiver.

type Doubler = struct { factor: i32 }

fn op_call(self: Doubler, x: i32) i32 {
    return self.factor * x
}

pub fn main() i32 {
    let d = Doubler { factor = 6 }
    return d(7)
}
