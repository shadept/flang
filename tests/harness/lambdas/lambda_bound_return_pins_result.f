//! TEST: lambda_bound_return_pins_result
//! EXIT: 0

// A generic result fixed only by the return of a trailing lambda in a bounded `$F` slot is inferred
// at the call, so the unannotated binding can be matched on at once.

type Event = enum {
    Got(i32)
    Stop
}

type Arms = struct(R) {
    result: R
    done: bool
}

fn first_arm(body: fn(&Arms($R))) R {
    let a: Arms(R)
    a.done = false
    body(&a)
    return move a.result
}

fn arm(self: &Arms($R), value: i32, handler: $F) where F: fn(i32) R {
    if !self.done {
        self.result = handler(value)
        self.done = true
    }
}

pub fn main() i32 {
    const e = first_arm { on =>
        on.arm(41) { Event.Got(it) }
    }
    return e match {
        Got(n) => n - 41
        Stop => 1
    }
}
