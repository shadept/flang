//! TEST: op_call_basic
//! EXIT: 6

// RFC-014 Phase 1: any type with `op_call` becomes callable as `t(args)`.
// Counter increments observable state on each invocation.

type Counter = struct { n: i32 }

fn op_call(self: &Counter) i32 {
    self.n = self.n + 1
    return self.n
}

pub fn main() i32 {
    let c = Counter { n = 0 }
    let a = c()
    let b = c()
    let d = c()
    return a + b + d
}
