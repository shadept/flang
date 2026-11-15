//! TEST: op_call_through_reference
//! EXIT: 0

// A value of reference type calls through its referent's op_call: a `&Counter` parameter, and a
// trailing lambda's parameter of generic type `&Arms(R)` whose `R` only a later handler fixes.

type Counter = struct { n: i32 }

fn op_call(self: &Counter, by: i32) i32 {
    self.n = self.n + by
    return self.n
}

fn bump(c: &Counter) i32 {
    return c(2)
}

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

fn op_call(self: &Arms($R), value: i32, handler: $F) where F: fn(i32) R {
    if !self.done {
        self.result = handler(value)
        self.done = true
    }
}

pub fn main() i32 {
    let c: Counter = Counter { n = 1 }
    if bump(&c) != 3 {
        return 1
    }
    const e: Event = first_arm { on =>
        on(41) { Event.Got(it) }
        on(7) { Event.Stop }
    }
    return e match {
        Got(n) => n - 41
        Stop => 2
    }
}
