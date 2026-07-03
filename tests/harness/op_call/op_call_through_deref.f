//! TEST: op_call_through_deref
//! EXIT: 6

// op_call resolves through op_deref: Wrapper(Counter)::op_call goes via Wrapper's
// op_deref to Counter::op_call. No special-casing for closures or wrappers.

type Counter = struct { n: i32 }

fn op_call(self: &Counter) i32 {
    self.n = self.n + 1
    return self.n
}

type Wrapper = struct(T) { __value: T }

fn op_deref(self: &Wrapper($T)) &T {
    return &self.__value
}

pub fn main() i32 {
    let w = Wrapper(Counter) { __value = Counter { n = 0 } }
    let a = w()  // 1
    let b = w()  // 2
    let c = w()  // 3
    return a + b + c
}
